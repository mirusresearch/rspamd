--[[
Copyright (c) 2017, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]] --

local rspamd_logger = require "rspamd_logger"
local lua_util = require "lua_util"
local fun = require "fun"
local auth_results = require "auth_results"
local hash = require "rspamd_cryptobox_hash"

if confighelp then
  return
end

local N = 'arc'
local dkim_verify = rspamd_plugins.dkim.verify
local dkim_sign = rspamd_plugins.dkim.sign
local dkim_canonicalize = rspamd_plugins.dkim.canon_header_relaxed
local redis_params

local arc_symbols = {
  allow = 'ARC_POLICY_ALLOW',
  invalid = 'ARC_BAD_POLICY',
  dnsfail = 'ARC_DNSFAIL',
  na = 'ARC_NA',
  reject = 'ARC_POLICY_REJECT',
}

local symbols = {
  spf_allow_symbol = 'R_SPF_ALLOW',
  spf_deny_symbol = 'R_SPF_FAIL',
  spf_softfail_symbol = 'R_SPF_SOFTFAIL',
  spf_neutral_symbol = 'R_SPF_NEUTRAL',
  spf_tempfail_symbol = 'R_SPF_DNSFAIL',
  spf_permfail_symbol = 'R_SPF_PERMFAIL',
  spf_na_symbol = 'R_SPF_NA',

  dkim_allow_symbol = 'R_DKIM_ALLOW',
  dkim_deny_symbol = 'R_DKIM_REJECT',
  dkim_tempfail_symbol = 'R_DKIM_TEMPFAIL',
  dkim_na_symbol = 'R_DKIM_NA',
  dkim_permfail_symbol = 'R_DKIM_PERMFAIL',
}

local settings = {
  allow_envfrom_empty = true,
  allow_hdrfrom_mismatch = false,
  allow_hdrfrom_mismatch_local = false,
  allow_hdrfrom_mismatch_sign_networks = false,
  allow_hdrfrom_multiple = false,
  allow_username_mismatch = false,
  auth_only = true,
  domain = {},
  path = string.format('%s/%s/%s', rspamd_paths['DBDIR'], 'arc', '$domain.$selector.key'),
  sign_local = true,
  selector = 'arc',
  sign_symbol = 'ARC_SIGNED',
  try_fallback = true,
  use_domain = 'header',
  use_esld = true,
  use_redis = false,
  key_prefix = 'arc_keys', -- default hash name
}

local function parse_arc_header(hdr, target)
  local arr = fun.totable(fun.map(
    function(val)
      return fun.totable(fun.map(lua_util.rspamd_str_trim,
        fun.filter(function(v) return v and #v > 0 end,
          lua_util.rspamd_str_split(val.decoded, ';'))))
    end, hdr
  ))

  -- Now we have two tables in format:
  -- [sigs] -> [{sig1_elts}, {sig2_elts}...]
  for i,elts in ipairs(arr) do
    fun.each(function(v)
      if not target[i] then target[i] = {} end
      if v[1] and v[2] then
        target[i][v[1]] = v[2]
      end
    end, fun.map(function(elt)
      return lua_util.rspamd_str_split(elt, '=')
    end, elts))
  end
end

local function arc_validate_seals(task, seals, sigs, seal_headers, sig_headers)
  for i = 1,#seals do
    if (sigs[i].i or 0) ~= i then
      rspamd_logger.infox(task, 'bad i value for signature: %s, expected %s',
        sigs[i].i, i)
      task:insert_result(arc_symbols['invalid'], 1.0, 'invalid count of seals and signatures')
      return false
    end
    if (seals[i].i or 0) ~= i then
      rspamd_logger.infox(task, 'bad i value for seal: %s, expected %s',
        seals[i].i, i)
      task:insert_result(arc_symbols['invalid'], 1.0, 'invalid count of seals and signatures')
      return false
    end

    if not seals[i].cv then
      task:insert_result(arc_symbols['invalid'], 1.0, 'no cv on i=' .. tostring(i))
      return false
    end

    if i == 1 then
      -- We need to ensure that cv of seal is equal to 'none'
      if seals[i].cv ~= 'none' then
        task:insert_result(arc_symbols['invalid'], 1.0, 'cv is not "none" for i=1')
        return false
      end
    else
      if seals[i].cv ~= 'pass' then
        task:insert_result(arc_symbols['reject'], 1.0, string.format('cv is %s on i=%d',
            seals[i].cv, i))
        return false
      end
    end

    sigs[i].header = sig_headers[i].decoded
    seals[i].header = seal_headers[i].decoded
    sigs[i].raw_header = sig_headers[i].raw
    seals[i].raw_header = seal_headers[i].raw
  end

  return true
end

local function arc_callback(task)
  local arc_sig_headers = task:get_header_full('ARC-Message-Signature')
  local arc_seal_headers = task:get_header_full('ARC-Seal')

  if not arc_sig_headers or not arc_seal_headers then
    task:insert_result(arc_symbols['na'], 1.0)
    return
  end

  if #arc_sig_headers ~= #arc_seal_headers then
    -- We mandate that count of seals is equal to count of signatures
    rspamd_logger.infox(task, 'number of seals (%s) is not equal to number of signatures (%s)',
        #arc_seal_headers, #arc_sig_headers)
    task:insert_result(arc_symbols['invalid'], 'invalid count of seals and signatures')
    return
  end

  local cbdata = {
    seals = {},
    sigs = {},
    checked = 0,
    res = 'success',
    errors = {}
  }

  parse_arc_header(arc_seal_headers, cbdata.seals)
  parse_arc_header(arc_sig_headers, cbdata.sigs)

  -- Fix i type
  fun.each(function(hdr)
    hdr.i = tonumber(hdr.i) or 0
  end, cbdata.seals)

  fun.each(function(hdr)
    hdr.i = tonumber(hdr.i) or 0
  end, cbdata.sigs)

  -- Now we need to sort elements according to their [i] value
  table.sort(cbdata.seals, function(e1, e2)
    return (e1.i or 0) < (e2.i or 0)
  end)
  table.sort(cbdata.sigs, function(e1, e2)
    return (e1.i or 0) < (e2.i or 0)
  end)

  rspamd_logger.debugm(N, task, 'got %s arc sections', #cbdata.seals)

  -- Now check sanity of what we have
  if not arc_validate_seals(task, cbdata.seals, cbdata.sigs,
    arc_seal_headers, arc_sig_headers) then
    return
  end

  task:cache_set('arc-sigs', cbdata.sigs)
  task:cache_set('arc-seals', cbdata.seals)

  local function arc_seal_cb(_, res, err, domain)
    cbdata.checked = cbdata.checked + 1
    rspamd_logger.debugm(N, task, 'checked arc seal: %s(%s), %s processed',
        res, err, cbdata.checked)

    if not res then
      cbdata.res = 'fail'
      if err and domain then
        table.insert(cbdata.errors, string.format('sig:%s:%s', domain, err))
      end
    end

    if cbdata.checked == #arc_sig_headers then
      if cbdata.res == 'success' then
        task:insert_result(arc_symbols['allow'], 1.0, cbdata.errors)
      else
        task:insert_result(arc_symbols['reject'], 1.0, cbdata.errors)
      end
    end
  end

  local function arc_signature_cb(_, res, err, domain)
    cbdata.checked = cbdata.checked + 1

    rspamd_logger.debugm(N, task, 'checked arc signature %s: %s(%s), %s processed',
      domain, res, err, cbdata.checked)

    if not res then
      cbdata.res = 'fail'
      if err and domain then
        table.insert(cbdata.errors, string.format('sig:%s:%s', domain, err))
      end
    end

    if cbdata.checked == #arc_sig_headers then
      if cbdata.res == 'success' then
        -- Verify seals
        cbdata.checked = 0
        fun.each(
          function(sig)
            local ret, lerr = dkim_verify(task, sig.header, arc_seal_cb, 'arc-seal')
            if not ret then
              cbdata.res = 'fail'
              table.insert(cbdata.errors, string.format('sig:%s:%s', sig.d or '', lerr))
              cbdata.checked = cbdata.checked + 1
              rspamd_logger.debugm(N, task, 'checked arc seal %s: %s(%s), %s processed',
                sig.d, ret, lerr, cbdata.checked)
            end
          end, cbdata.seals)
      else
        task:insert_result(arc_symbols['reject'], 1.0, cbdata.errors)
      end
    end
  end

  -- Now we can verify all signatures
  fun.each(
    function(sig)
      local ret,err = dkim_verify(task, sig.header, arc_signature_cb, 'arc-sign')

      if not ret then
        cbdata.res = 'fail'
        table.insert(cbdata.errors, string.format('sig:%s:%s', sig.d or '', err))
        cbdata.checked = cbdata.checked + 1
        rspamd_logger.debugm(N, task, 'checked arc sig %s: %s(%s), %s processed',
          sig.d, ret, err, cbdata.checked)
      end
    end, cbdata.sigs)

  if cbdata.checked == #arc_sig_headers then
    task:insert_result(arc_symbols['reject'], 1.0, cbdata.errors)
  end
end

local opts = rspamd_config:get_all_opt('arc')
if not opts or type(opts) ~= 'table' then
  return
end

if opts['symbols'] then
  for k,_ in pairs(arc_symbols) do
    if opts['symbols'][k] then
      arc_symbols[k] = opts['symbols'][k]
    end
  end
end


local id = rspamd_config:register_symbol({
  name = 'ARC_CALLBACK',
  type = 'callback',
  callback = arc_callback
})

rspamd_config:register_symbol({
  name = arc_symbols['allow'],
  flags = 'nice',
  parent = id,
  type = 'virtual',
  score = -1.0,
  group = 'arc',
})
rspamd_config:register_symbol({
  name = arc_symbols['reject'],
  parent = id,
  type = 'virtual',
  score = 2.0,
  group = 'arc',
})
rspamd_config:register_symbol({
  name = arc_symbols['invalid'],
  parent = id,
  type = 'virtual',
  score = 1.0,
  group = 'arc',
})
rspamd_config:register_symbol({
  name = arc_symbols['dnsfail'],
  parent = id,
  type = 'virtual',
  score = 0.0,
  group = 'arc',
})
rspamd_config:register_symbol({
  name = arc_symbols['na'],
  parent = id,
  type = 'virtual',
  score = 0.0,
  group = 'arc',
})

rspamd_config:register_dependency(id, symbols['spf_allow_symbol'])
rspamd_config:register_dependency(id, symbols['dkim_allow_symbol'])

-- Signatures part
local function simple_template(tmpl, keys)
  local lpeg = require "lpeg"

  local var_lit = lpeg.P { lpeg.R("az") + lpeg.R("AZ") + lpeg.R("09") + "_" }
  local var = lpeg.P { (lpeg.P("$") / "") * ((var_lit^1) / keys) }
  local var_braced = lpeg.P { (lpeg.P("${") / "") * ((var_lit^1) / keys) * (lpeg.P("}") / "") }

  local template_grammar = lpeg.Cs((var + var_braced + 1)^0)

  return lpeg.match(template_grammar, tmpl)
end

local function arc_sign_seal(task, params, header)
  local arc_sigs = task:cache_get('arc-sigs')
  local arc_seals = task:cache_get('arc-seals')
  local arc_auth_results = task:get_header_full('ARC-Authentication-Results') or {}
  local cur_auth_results = auth_results.gen_auth_results() or ''

  local sha_ctx = hash.create('sha-256')

  -- Update using previous seals + sigs + AAR
  local cur_idx = 1
  if arc_seals then
    cur_idx = #arc_seals + 1
    for i = (cur_idx - 1), 1, (-1) do
      if arc_auth_results[i] then
        sha_ctx:update(dkim_canonicalize('ARC-Authentication-Results',
          arc_auth_results[i].raw))
      end
      if arc_sigs[i] then
        sha_ctx:update(dkim_canonicalize('ARC-Message-Signature',
          arc_sigs[i].raw_header))
      end
      if arc_seals[i] then
        sha_ctx:update(dkim_canonicalize('ARC-Seal', arc_seals[i].raw_header))
      end
    end
  end

  cur_auth_results = string.format('i=%d; %s', #arc_seals + 1, cur_auth_results)
  sha_ctx:update(dkim_canonicalize('ARC-Authentication-Results',
    cur_auth_results))
  sha_ctx:update(dkim_canonicalize('ARC-Message-Signature',
    header))

  local cur_arc_seal = string.format('i=%d; s=%s; d=%s; t=%d; a=rsa-sha256; cv=%s; b=',
      cur_idx, params.selector, params.domain, rspamd_util.get_time(), params.cv)
  sha_ctx:update(dkim_canonicalize('ARC-Message-Signature',
    cur_arc_seal))
  -- TODO: implement proper interface for RSA signatures

end

local function arc_signing_cb(task)
  local arc_sigs = task:cache_get('arc-sigs')
  local arc_seals = task:cache_get('arc-seals')
  local is_local, is_sign_networks
  local auser = task:get_user()
  local ip = task:get_from_ip()

  if ip and ip:is_local() then
    is_local = true
  end
  if settings.auth_only and not auser then
    if (settings.sign_networks and settings.sign_networks:get_key(ip)) then
      is_sign_networks = true
      rspamd_logger.debugm(N, task, 'mail is from address in sign_networks')
    elseif settings.sign_local and is_local then
      rspamd_logger.debugm(N, task, 'mail is from local address')
    else
      rspamd_logger.debugm(N, task, 'ignoring unauthenticated mail')
      return
    end
  end
  local efrom = task:get_from('smtp')
  if not settings.allow_envfrom_empty and
      #(((efrom or E)[1] or E).addr or '') == 0 then
    rspamd_logger.debugm(N, task, 'empty envelope from not allowed')
    return false
  end
  local hfrom = task:get_from('mime')
  if not settings.allow_hdrfrom_multiple and (hfrom or E)[2] then
    rspamd_logger.debugm(N, task, 'multiple header from not allowed')
    return false
  end
  local dkim_domain
  local hdom = ((hfrom or E)[1] or E).domain
  local edom = ((efrom or E)[1] or E).domain
  if hdom then
    hdom = hdom:lower()
  end
  if edom then
    edom = edom:lower()
  end
  if settings.use_domain_sign_networks and is_sign_networks then
    if settings.use_domain_sign_networks == 'header' then
      dkim_domain = hdom
    else
      dkim_domain = edom
    end
  elseif settings.use_domain_local and is_local then
    if settings.use_domain_local == 'header' then
      dkim_domain = hdom
    else
      dkim_domain = edom
    end
  else
    if settings.use_domain == 'header' then
      dkim_domain = hdom
    else
      dkim_domain = edom
    end
  end
  if not dkim_domain then
    rspamd_logger.debugm(N, task, 'could not extract dkim domain')
    return false
  end
  if settings.use_esld then
    dkim_domain = rspamd_util.get_tld(dkim_domain)
    if settings.use_domain == 'envelope' and hdom then
      hdom = rspamd_util.get_tld(hdom)
    elseif settings.use_domain == 'header' and edom then
      edom = rspamd_util.get_tld(edom)
    end
  end
  if edom and hdom and not settings.allow_hdrfrom_mismatch and hdom ~= edom then
    if settings.allow_hdrfrom_mismatch_local and is_local then
      rspamd_logger.debugm(N, task, 'domain mismatch allowed for local IP: %1 != %2', hdom, edom)
    elseif settings.allow_hdrfrom_mismatch_sign_networks and is_sign_networks then
      rspamd_logger.debugm(N, task, 'domain mismatch allowed for sign_networks: %1 != %2', hdom, edom)
    else
      rspamd_logger.debugm(N, task, 'domain mismatch not allowed: %1 != %2', hdom, edom)
      return false
    end
  end
  if auser and not settings.allow_username_mismatch then
    local udom = string.match(auser, '.*@(.*)')
    if not udom then
      rspamd_logger.debugm(N, task, 'couldnt find domain in username')
      return false
    end
    if settings.use_esld then
      udom = rspamd_util.get_tld(udom)
    end
    if udom ~= dkim_domain then
      rspamd_logger.debugm(N, task, 'user domain mismatch')
      return false
    end
  end
  local p = {}
  if settings.domain[dkim_domain] then
    p.selector = settings.domain[dkim_domain].selector
    p.key = settings.domain[dkim_domain].path
  end
  if not (p.key and p.selector) and not
  (settings.try_fallback or settings.use_redis or settings.selector_map or settings.path_map) then
    rspamd_logger.debugm(N, task, 'dkim unconfigured and fallback disabled')
    return false
  end
  if not p.key then
    if not settings.use_redis then
      p.key = settings.path
    end
  end
  if not p.selector then
    p.selector = settings.selector
  end
  p.domain = dkim_domain

  if settings.selector_map then
    local data = settings.selector_map:get_key(dkim_domain)
    if data then
      p.selector = data
    end
  end
  if settings.path_map then
    local data = settings.path_map:get_key(dkim_domain)
    if data then
      p.key = data
    end
  end

  p.arc_cv = 'none'
  p.arc_idx = 1
  p.no_cache = true

  if arc_seals then
    p.arc_idx = #arc_seals + 1

    if task:has_symbol(arc_symbols.allow) then
      p.arc_cv = 'pass'
    else
      p.arc_cv = 'fail'
    end
  end

  if settings.use_redis then
    local function try_redis_key(selector)
      p.key = nil
      p.selector = selector
      p.sign_type = 'arc-sign'
      local rk = string.format('%s.%s', p.selector, p.domain)
      local function redis_key_cb(err, data)
        if err or type(data) ~= 'string' then
          rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM key for %s: %s",
            rk, err)
        else
          p.rawkey = data
          local ret, hdr = dkim_sign(task, p)
          if ret then
            return arc_sign_seal(task, p, hdr)
          end
        end
      end
      local ret = rspamd_redis_make_request(task,
        redis_params, -- connect params
        rk, -- hash key
        false, -- is write
        redis_key_cb, --callback
        'HGET', -- command
        {settings.key_prefix, rk} -- arguments
      )
      if not ret then
        rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM key for %s", rk)
      end
    end
    if settings.selector_prefix then
      rspamd_logger.infox(rspamd_config, "Using selector prefix %s for domain %s", settings.selector_prefix, p.domain);
      local function redis_selector_cb(err, data)
        if err or type(data) ~= 'string' then
          rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM selector for domain %s: %s", p.domain, err)
        else
          try_redis_key(data)
        end
      end
      local ret = rspamd_redis_make_request(task,
        redis_params, -- connect params
        p.domain, -- hash key
        false, -- is write
        redis_selector_cb, --callback
        'HGET', -- command
        {settings.selector_prefix, p.domain} -- arguments
      )
      if not ret then
        rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM selector for %s", p.domain)
      end
    else
      if not p.selector then
        rspamd_logger.errx(task, 'No selector specified')
        return false
      end
      try_redis_key(p.selector)
    end
  else
    if (p.key and p.selector) then
      p.key = simple_template(p.key, {domain = p.domain, selector = p.selector})
      local ret, hdr = dkim_sign(task, p)
      if ret then
        return arc_sign_seal(task, p, hdr)
      end
    else
      rspamd_logger.infox(task, 'key path or dkim selector unconfigured; no signing')
      return false
    end
  end
end

local opts =  rspamd_config:get_all_opt('arc')
if not opts then return end
for k,v in pairs(opts) do
  if k == 'sign_networks' then
    settings[k] = rspamd_map_add(N, k, 'radix', 'DKIM signing networks')
  elseif k == 'path_map' then
    settings[k] = rspamd_map_add(N, k, 'map', 'Paths to DKIM signing keys')
  elseif k == 'selector_map' then
    settings[k] = rspamd_map_add(N, k, 'map', 'DKIM selectors')
  else
    settings[k] = v
  end
end
if not (settings.use_redis or settings.path or
    settings.domain or settings.path_map or settings.selector_map) then
  rspamd_logger.infox(rspamd_config, 'mandatory parameters missing, disable arc signing')
  return
end

if settings.use_redis then
  redis_params = rspamd_parse_redis_server('arc')

  if not redis_params then
    rspamd_logger.errx(rspamd_config, 'no servers are specified, but module is configured to load keys from redis, disable dkim signing')
    return
  end
end

if settings.use_domain ~= 'header' and settings.use_domain ~= 'envelope' then
  rspamd_logger.errx(rspamd_config, "Value for 'use_domain' is invalid")
  settings.use_domain = 'header'
end

id = rspamd_config:register_symbol({
  name = settings['sign_symbol'],
  callback = arc_signing_cb
})

-- Do not sign unless valid
rspamd_config:register_dependency(id, 'ARC_CALLBACK')