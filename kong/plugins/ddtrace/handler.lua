local new_sampler = require("kong.plugins.ddtrace.sampler").new
local new_trace_agent_writer = require("kong.plugins.ddtrace.agent_writer").new
local new_propagator = require("kong.plugins.ddtrace.propagation").new
local utils = require("kong.plugins.ddtrace.utils")

local pcall = pcall
local subsystem = ngx.config.subsystem
local fmt = string.format
local strsub = string.sub
local regex = ngx.re
local btohex = bit.tohex

local DatadogTraceHandler = {
    VERSION = "0.2.2",
    -- We want to run first so that timestamps taken are at start of the phase.
    -- However, it might be useful to finish spans after other plugins have completed
    -- to more accurately represent the request completion time.
    PRIORITY = 100000,
}

-- This cache is keyed on Kong's config object. Setting the mode to weak ensures
-- the keys will get garbage-collected when the config object's lifecycle is completed.
local agent_writer_cache = setmetatable({}, { __mode = "k" })
local function flush_agent_writers()
    for conf, agent_writer in pairs(agent_writer_cache) do
        local ok, err = agent_writer:flush()
        if not ok then
            kong.log.err("agent_writer error ", err)
        end
    end
end

-- This timer runs in the background to flush traces for all instances of the plugin.
-- Because of the way timers work in lua, this can only be initialized when there's an
-- active request. This gets initialized on the first request this plugin handles.
local agent_writer_timer -- luacheck: ignore 231
local propagator
local sampler
local header_tags
local ddtrace_conf

local ngx_now = ngx.now

-- Memoize some data attached to traces
local ngx_worker_pid = ngx.worker.pid()
local ngx_worker_id = ngx.worker.id()
local ngx_worker_count = ngx.worker.count()
-- local kong_cluster_id = kong.cluster.get_id()
local kong_node_id = kong.node.get_id()

-- ngx.now in microseconds
local function ngx_now_mu()
    return ngx_now() * 1000000
end

local function get_agent_writer(conf, agent_url)
    if agent_writer_cache[conf] == nil then
        agent_writer_cache[conf] = new_trace_agent_writer(agent_url, sampler, DatadogTraceHandler.VERSION)
    end
    return agent_writer_cache[conf]
end

local function tag_with_service_and_route(span)
    local service = kong.router.get_service()
    if service and service.id then
        span:set_tag("kong.service", service.id)
        if type(service.name) == "string" then
            span.service_name = service.name
            span:set_tag("kong.service_name", service.name)
        end
    end

    local route = kong.router.get_route()
    if route then
        if route.id then
            span:set_tag("kong.route", route.id)
        end
        if type(route.name) == "string" then
            span:set_tag("kong.route_name", route.name)
        end
    else
        span:set_tag("kong.route", "none")
    end
end

local function expose_tracing_variables(span)
    -- Expose traceID and parentID for other plugin to consume and also set an NGINX variable
    -- that can be use for in `log_format` directive for correlation with logs.
    local trace_id = btohex(span.trace_id.high or 0, 16) .. btohex(span.trace_id.low, 16)
    local span_id = btohex(span.span_id, 16)

    -- NOTE: kong.ctx has the same lifetime as the current request.
    local kong_shared = kong.ctx.shared
    kong_shared.datadog_sdk_trace_id = trace_id
    kong_shared.datadog_sdk_span_id = span_id
end

-- adds the proxy span to the datadog context, unless it already exists
local function get_or_add_proxy_span(datadog, timestamp)
    if not datadog.proxy_span then
        local request_span = datadog.request_span
        local proxy_span = request_span:new_child("kong.proxy", request_span.resource, timestamp)
        proxy_span:set_tag("span.kind", "client")
        datadog.proxy_span = proxy_span
        expose_tracing_variables(proxy_span)
    end
    return datadog.proxy_span
end

local initialize_request

-- initialize the request span and datadog context
-- if being called the first time for this request.
-- the new or existing context is retured.
local function get_datadog_context(conf, ctx)
    local datadog = ctx.datadog
    if not datadog then
        initialize_request(conf, ctx)
        datadog = ctx.datadog
    end
    return datadog
end

-- check if a datadog context exists.
-- used in the log phase to ensure we captured tracing data.
local function has_datadog_context(ctx)
    if ctx.datadog then
        return true
    end
    return false
end

-- apply resource_name_rules to the provided URI
-- and return a replacement value.
local function apply_resource_name_rules(uri, rules)
    if rules then
        for _, rule in ipairs(rules) do
            -- try to match URI to rule's expression
            local from, to, _ = regex.find(uri, rule.match, "ajo")
            if from then
                local matched_uri = strsub(uri, from, to)
                -- if we have a match but no replacement, return the matched value
                if not rule.replacement then
                    return matched_uri
                end
                local replaced_uri, _, _ = regex.sub(matched_uri, rule.match, rule.replacement, "ajo")
                if replaced_uri then
                    return replaced_uri
                end
            end
        end
    end

    -- no rules matched or errors occured, apply a default rule
    -- decompose path into fragments, and replace parts with excessive digits with ?,
    -- except if it looks like a version identifier (v1, v2 etc) or if it is
    -- a status / health check
    local fragments = {}
    local it, _ = regex.gmatch(uri, "(/[^/]*)", "jo")
    if not it then
        return uri
    end
    while true do
        local fragment_table = it()
        if not fragment_table then
            break
        end
        -- the iterator returns a table, but it should only have one item in it
        local fragment = fragment_table[1]
        table.insert(fragments, fragment)
    end
    for i, fragment in ipairs(fragments) do
        local token = strsub(fragment, 2)
        local version_match = regex.match(token, "v\\d+", "ajo")
        if version_match then
            -- no ? substitution for versions
            goto continue
        end

        local token_len = #token
        local _, digits, _ = regex.gsub(token, "\\d", "", "jo")
        if token_len <= 5 and digits > 2 or token_len > 5 and digits > 3 then
            -- apply the substitution
            fragments[i] = "/?"
        end
        ::continue::
    end

    return table.concat(fragments)
end

local function configure(conf)
    local get_from_vault = kong.vault.get
    local get_env = function(env_name)
        local env_value, _ = get_from_vault(string.format("{vault://env/%s}", env_name))
        if env_value and #env_value == 0 then
            return nil
        end
        return env_value
    end

    -- Build agent url
    local agent_host = get_env("DD_AGENT_HOST") or conf.agent_host or "localhost"
    local agent_port = get_env("DD_TRACE_AGENT_PORT") or conf.trace_agent_port or "8126"
    if type(agent_port) ~= "string" then
        agent_port = tostring(agent_port)
    end
    local agent_url = string.format("http://%s:%s", agent_host, agent_port)

    ddtrace_conf = {
        __id__ = conf["__seq__"],
        service = get_env("DD_SERVICE") or conf.service_name or "kong",
        environment = get_env("DD_ENV") or conf.environment,
        version = get_env("DD_VERSION") or conf.version,
        agent_url = get_env("DD_TRACE_AGENT_URL") or conf.trace_agent_url or agent_url,
        injection_propagation_styles = conf.injection_propagation_styles,
        extraction_propagation_styles = conf.extraction_propagation_styles,
    }

    kong.log.debug("DATADOG TRACER CONFIGURATION - " .. utils.dump(ddtrace_conf))

    agent_writer_timer = ngx.timer.every(2.0, flush_agent_writers)
    sampler = new_sampler(math.ceil(conf.initial_samples_per_second / ngx_worker_count), conf.initial_sample_rate)
    propagator = new_propagator(
        ddtrace_conf.extraction_propagation_styles,
        ddtrace_conf.injection_propagation_styles,
        conf.max_header_size
    )

    if conf and conf.header_tags then
        header_tags = utils.normalize_header_tags(conf.header_tags)
    end
end

if subsystem == "http" then
    initialize_request = function(conf, ctx)
        if not ddtrace_conf or conf["__seq__"] ~= ddtrace_conf["__id__"] then
            -- NOTE(@dmehala): Kong versions older than 3.5 do not call `plugin:configure` method.
            -- `configure` will be called only on the first request or when the configuration has
            -- been updated.
            configure(conf)
        end

        local req = kong.request
        local method = req.get_method()
        local path = req.get_path()

        local span_options = {
            service = ddtrace_conf.service,
            name = "kong.request",
            start_us = ngx.ctx.KONG_PROCESSING_START * 1000000LL,
            -- TODO: decrease cardinality of path value
            resource = method .. " " .. apply_resource_name_rules(path, conf.resource_name_rule),
            generate_128bit_trace_ids = conf.generate_128bit_trace_ids,
        }

        local request_span = propagator:extract_or_create_span(req, span_options)

        -- Set datadog tags
        if ddtrace_conf.environment then
            request_span:set_tag("env", ddtrace_conf.environment)
        end
        if ddtrace_conf.version then
            request_span:set_tag("version", ddtrace_conf.version)
        end

        -- TODO: decide about deferring sampling decision until injection or not
        if not request_span.sampling_priority then
            sampler:sample(request_span)
        end

        -- Add metrics
        request_span.metrics["_dd.top_level"] = 1

        -- Set standard tags
        request_span:set_tag("component", "kong")
        request_span:set_tag("span.kind", "server")

        local url = req.get_scheme() .. "://" .. req.get_host() .. ":" .. req.get_port() .. path
        request_span:set_tag("http.method", method)
        request_span:set_tag("http.url", url)
        request_span:set_tag("http.client_ip", kong.client.get_forwarded_ip())
        request_span:set_tag("http.request.content_length", req.get_header("content-length"))
        request_span:set_tag("http.useragent", req.get_header("user-agent"))
        request_span:set_tag("http.version", req.get_http_version())

        -- Set nginx informational tags
        request_span:set_tag("nginx.version", ngx.config.nginx_version)
        request_span:set_tag("nginx.lua_version", ngx.config.ngx_lua_version)
        request_span:set_tag("nginx.worker_pid", ngx_worker_pid)
        request_span:set_tag("nginx.worker_id", ngx_worker_id)
        request_span:set_tag("nginx.worker_count", ngx_worker_count)

        -- Set kong informational tags
        request_span:set_tag("kong.version", kong.version)
        request_span:set_tag("kong.pdk_version", kong.pdk_version)
        request_span:set_tag("kong.node_id", kong_node_id)

        if kong.configuration then
            request_span:set_tag("kong.role", kong.configuration.role)
            request_span:set_tag("kong.nginx_daemon", kong.configuration.nginx_daemon)
            request_span:set_tag("kong.database", kong.configuration.database)
        end

        local static_tags = conf and conf.static_tags or nil
        if type(static_tags) == "table" then
            for i = 1, #static_tags do
                local tag = static_tags[i]
                request_span:set_tag(tag.name, tag.value)
            end
        end

        expose_tracing_variables(request_span)

        ctx.datadog = {
            request_span = request_span,
            proxy_span = nil,
            header_filter_finished = false,
        }
    end

    function DatadogTraceHandler:configure(configs)
        local conf = configs and configs[1] or nil
        if conf then
            local ok, message = pcall(function()
                configure(conf)
            end)
            if not ok then
                kong.log.err("failed to configure ddtrace:" .. message)
            end
        end
    end

    function DatadogTraceHandler:rewrite(conf)
        local ok, message = pcall(function()
            self:rewrite_p(conf)
        end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:rewrite: " .. message)
        end
    end

    function DatadogTraceHandler:rewrite_p(conf)
        -- TODO: reconsider tagging rewrite-start timestamps on request spans
    end

    function DatadogTraceHandler:access(conf)
        local ok, message = pcall(function()
            self:access_p(conf)
        end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:access: " .. message)
        end
    end

    function DatadogTraceHandler:access_p(conf)
        local datadog = get_datadog_context(conf, kong.ctx.plugin)
        local ngx_ctx = ngx.ctx

        local access_start = ngx_ctx.KONG_ACCESS_START and ngx_ctx.KONG_ACCESS_START * 1000 or ngx_now_mu()
        local proxy_span = get_or_add_proxy_span(datadog, access_start * 1000LL)

        local request = {
            get_header = kong.request.get_header,
            set_header = kong.service.request.set_header,
        }

        local err = propagator:inject(request, proxy_span)
        if err then
            kong.log.error("Failed to inject trace (id: " .. proxy_span.trace_id .. "). Reason: " .. err)
        end
    end

    function DatadogTraceHandler:header_filter(conf) -- luacheck: ignore 212
        local ok, message = pcall(function()
            self:header_filter_p(conf)
        end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:header_filter: " .. message)
        end
    end

    function DatadogTraceHandler:header_filter_p(conf) -- luacheck: ignore 212
        local datadog = get_datadog_context(conf, kong.ctx.plugin)
        local ngx_ctx = ngx.ctx
        local header_filter_start_mu = ngx_ctx.KONG_HEADER_FILTER_STARTED_AT
                and ngx_ctx.KONG_HEADER_FILTER_STARTED_AT * 1000
            or ngx_now_mu()

        get_or_add_proxy_span(datadog, header_filter_start_mu * 1000LL)
    end

    function DatadogTraceHandler:body_filter(conf) -- luacheck: ignore 212
        local ok, message = pcall(function()
            self:body_filter_p(conf)
        end)
        if not ok then
            kong.log.err("tracing error in DatadogTraceHandler:body_filter: " .. message)
        end
    end

    function DatadogTraceHandler:body_filter_p(conf) -- luacheck: ignore 212
        local datadog = get_datadog_context(conf, kong.ctx.plugin)

        -- Finish header filter when body filter starts
        if not datadog.header_filter_finished then
            datadog.header_filter_finished = true
        end
    end

    -- TODO: consider handling stream subsystem
end

function DatadogTraceHandler:log(conf) -- luacheck: ignore 212
    local ok, message = pcall(function()
        self:log_p(conf)
    end)
    if not ok then
        kong.log.err("tracing error in DatadogTraceHandler:log: " .. message)
    end
end

function DatadogTraceHandler:log_p(conf) -- luacheck: ignore 212
    if not has_datadog_context(kong.ctx.plugin) then
        return
    end

    local now_mu = ngx_now_mu()
    local datadog = get_datadog_context(conf, kong.ctx.plugin)
    local ngx_ctx = ngx.ctx
    local request_span = datadog.request_span
    local proxy_span = get_or_add_proxy_span(datadog, now_mu * 1000LL)
    local agent_writer = get_agent_writer(conf, ddtrace_conf.agent_url)

    local proxy_finish_mu = ngx_ctx.KONG_BODY_FILTER_ENDED_AT and ngx_ctx.KONG_BODY_FILTER_ENDED_AT * 1000 or now_mu
    local request_finish_mu = ngx_ctx.KONG_LOG_START and ngx_ctx.KONG_LOG_START * 1000 or now_mu

    -- TODO: consider handling stream subsystem

    local balancer_data = ngx_ctx.balancer_data
    if balancer_data then
        local balancer_tries = balancer_data.tries
        local try_count = balancer_data.try_count

        proxy_span:set_tag("peer.hostname", balancer_data.hostname)
        proxy_span:set_tag("peer.ip", balancer_data.ip)
        proxy_span:set_tag("peer.port", balancer_data.port)
        proxy_span:set_tag("kong.balancer.tries", try_count)

        for i = 1, try_count do
            local tag_prefix = fmt("kong.balancer.try-%d.", i)
            local try = balancer_tries[i]
            if i < try_count then
                proxy_span:set_tag(tag_prefix .. "error", true)
                proxy_span:set_tag(tag_prefix .. "state", try.state)
                proxy_span:set_tag(tag_prefix .. "status_code", try.code)
            end
            if try.balancer_latency then
                proxy_span:set_tag(tag_prefix .. "latency", try.balancer_latency)
            end
        end
    end

    if subsystem == "http" then
        local status_code = kong.response.get_status()
        request_span:set_tag("http.status_code", status_code)
        -- TODO: allow user to define additional status codes that are treated as errors.
        if status_code >= 500 then
            request_span:set_tag("error", true)
            request_span.error = status_code
        end

        if header_tags then
            request_span:set_http_header_tags(header_tags, kong.request.get_header, kong.response.get_header)
        end
    end
    if ngx_ctx.authenticated_consumer then
        request_span:set_tag("kong.consumer", ngx_ctx.authenticated_consumer.id)
    end
    if conf and conf.include_credential and ngx_ctx.authenticated_credential then
        request_span:set_tag("kong.credential", ngx_ctx.authenticated_credential.id)
    end
    tag_with_service_and_route(proxy_span)

    proxy_span:finish(proxy_finish_mu * 1000LL)
    request_span:finish(request_finish_mu * 1000LL)
    agent_writer:add({ request_span, proxy_span })
end

return DatadogTraceHandler
