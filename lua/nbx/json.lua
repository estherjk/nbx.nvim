-- JSON encoder that writes exactly what nbformat writes: one space of indent,
-- sorted keys, non-ASCII left alone. A notebook saved here diffs cleanly
-- against one saved by Jupyter.
local M = {}

local empty_dict_mt = getmetatable(vim.empty_dict())

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_char(c)
  return escapes[c] or string.format("\\u%04x", c:byte())
end

local function encode_string(s)
  return '"' .. (s:gsub('[%z\1-\31"\\]', escape_char)) .. '"'
end

local function encode_number(n)
  if n ~= n then
    return "NaN"
  elseif n == math.huge then
    return "Infinity"
  elseif n == -math.huge then
    return "-Infinity"
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return string.format("%d", n)
  end
  for precision = 15, 17 do
    local s = string.format("%." .. precision .. "g", n)
    if tonumber(s) == n then
      return s
    end
  end
  return string.format("%.17g", n)
end

function M.is_dict(t)
  if getmetatable(t) == empty_dict_mt then
    return true
  end
  return next(t) ~= nil and not vim.islist(t)
end

local function encode(v, depth, out)
  local t = type(v)
  if v == nil or v == vim.NIL then
    out[#out + 1] = "null"
  elseif t == "string" then
    out[#out + 1] = encode_string(v)
  elseif t == "number" then
    out[#out + 1] = encode_number(v)
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "table" then
    local pad = string.rep(" ", depth + 1)
    if M.is_dict(v) then
      local keys = {}
      for k in pairs(v) do
        keys[#keys + 1] = tostring(k)
      end
      if #keys == 0 then
        out[#out + 1] = "{}"
        return
      end
      table.sort(keys)
      out[#out + 1] = "{\n"
      for i, k in ipairs(keys) do
        out[#out + 1] = pad .. encode_string(k) .. ": "
        local value = v[k]
        if value == nil then
          value = v[tonumber(k)]
        end
        encode(value, depth + 1, out)
        out[#out + 1] = i < #keys and ",\n" or "\n"
      end
      out[#out + 1] = string.rep(" ", depth) .. "}"
    else
      if #v == 0 then
        out[#out + 1] = "[]"
        return
      end
      out[#out + 1] = "[\n"
      for i, item in ipairs(v) do
        out[#out + 1] = pad
        encode(item, depth + 1, out)
        out[#out + 1] = i < #v and ",\n" or "\n"
      end
      out[#out + 1] = string.rep(" ", depth) .. "]"
    end
  else
    error("nbx: cannot encode a " .. t .. " as JSON")
  end
end

---@param value any
---@return string
function M.encode(value)
  local out = {}
  encode(value, 0, out)
  return table.concat(out)
end

---@param text string
function M.decode(text)
  return vim.json.decode(text, { luanil = { object = false, array = false } })
end

return M
