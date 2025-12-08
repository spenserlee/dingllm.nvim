local M = {}
local Job = require 'plenary.job'
local ns_id = vim.api.nvim_create_namespace 'dingllm'

local function get_api_key(name)
  return os.getenv(name)
end

-- Returns the lines from the top of the buffer up to the cursor
-- Returns a table (array) of strings, not a single string
function M.get_lines_until_cursor()
  local current_buffer = vim.api.nvim_get_current_buf()
  local current_window = vim.api.nvim_get_current_win()
  local cursor_position = vim.api.nvim_win_get_cursor(current_window)
  local row = cursor_position[1]

  -- Get all lines from start to cursor row
  local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)
  return lines
end

function M.get_visual_selection()
  local _, srow, scol = unpack(vim.fn.getpos 'v')
  local _, erow, ecol = unpack(vim.fn.getpos '.')

  if vim.fn.mode() == 'V' then
    if srow > erow then
      return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
    else
      return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
    end
  end

  if vim.fn.mode() == 'v' then
    if srow < erow or (srow == erow and scol <= ecol) then
      return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
    else
      return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
    end
  end

  if vim.fn.mode() == '\22' then
    local lines = {}
    if srow > erow then
      srow, erow = erow, srow
    end
    if scol > ecol then
      scol, ecol = ecol, scol
    end
    for i = srow, erow do
      table.insert(lines, vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1])
    end
    return lines
  end
end

-- Parser to convert Markdown buffer into Gemini History API format
-- Heuristic: Lines starting with "# User" or "## User" start a user block.
-- Lines starting with "# Model" or "## Model" start a model block.
function M.parse_gemini_history(lines)
  local contents = {}
  local current_role = "user" -- Default to user for the start
  local current_text = {}

  for _, line in ipairs(lines) do
    local is_user_header = line:match("^#+ User") or line:match("^%*%*User%*%*")
    local is_model_header = line:match("^#+ Model") or line:match("^#+ AI") or line:match("^%*%*Model%*%*")

    if is_user_header or is_model_header then
      -- Push previous block if it exists
      if #current_text > 0 then
        table.insert(contents, {
          role = current_role,
          parts = { { text = table.concat(current_text, "\n") } }
        })
      end
      -- Reset for new block
      current_text = {}
      if is_user_header then current_role = "user" end
      if is_model_header then current_role = "model" end
    else
      table.insert(current_text, line)
    end
  end

  -- Push final block
  if #current_text > 0 then
    table.insert(contents, {
      role = current_role,
      parts = { { text = table.concat(current_text, "\n") } }
    })
  end

  -- Fallback: If no headers were found, treat everything as one User prompt
  if #contents == 0 then
    return { { role = "user", parts = { { text = table.concat(lines, "\n") } } } }
  end

  return contents
end

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
  -- Legacy handling: Anthropic implementation here treats 'prompt' as a string
  local url = opts.url
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local data = {
    system = system_prompt,
    messages = { { role = 'user', content = prompt } },
    model = opts.model,
    stream = true,
    max_tokens = 4096,
  }

  local temp_file = vim.fn.tempname()
  local file = io.open(temp_file, "w")
  if not file then return nil, nil end
  file:write(vim.json.encode(data))
  file:close()

  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', '@' .. temp_file }
  if api_key then
    table.insert(args, '-H'); table.insert(args, 'x-api-key: ' .. api_key)
    table.insert(args, '-H'); table.insert(args, 'anthropic-version: 2023-06-01')
  end
  table.insert(args, url)
  return args, temp_file
end

function M.make_gemini_spec_curl_args(opts, prompt_data, system_prompt)
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local url = opts.url .. "/" .. opts.model .. ":streamGenerateContent?alt=sse&key=" .. api_key

  local contents_payload = {}

  -- Logic: If we are replacing (Visual mode), prompt_data is a String.
  -- If we are Chatting (Normal mode), prompt_data is a Table of lines (for parsing).
  if opts.replace then
      contents_payload = { { role = "user", parts = { { text = prompt_data } } } }
  else
      -- It is a table of lines, parse it into history
      if type(prompt_data) == "table" then
        contents_payload = M.parse_gemini_history(prompt_data)
      else
        -- Fallback if something went wrong and a string was passed
        contents_payload = { { role = "user", parts = { { text = prompt_data } } } }
      end
  end

  local data = { contents = contents_payload }

  if system_prompt and system_prompt ~= "" then
    data.systemInstruction = { parts = { { text = system_prompt } } }
  end

  local temp_file = vim.fn.tempname()
  local file, err = io.open(temp_file, "w")
  if not file then
    print("Error creating temporary file: " .. err)
    return nil, nil
  end

  local success, write_err = pcall(function() file:write(vim.json.encode(data)) end)
  if not success then
    print("Error writing to temporary file: " .. write_err)
    file:close(); vim.fn.delete(temp_file)
    return nil, nil
  end
  file:close()

  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', '@' .. temp_file }
  table.insert(args, url)
  return args, temp_file
end

function M.write_string_at_extmark(str, buf_id, extmark_id)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf_id) then return end

    local extmark = vim.api.nvim_buf_get_extmark_by_id(buf_id, ns_id, extmark_id, { details = false })
    if not extmark then return end
    local row, col = extmark[1], extmark[2]

    local success, err = pcall(vim.cmd, 'undojoin')
    if not success and err and not err:match 'E790' then
        -- Silently ignore E790 (undo join not allowed after undo), print others
        print("Error in undojoin: " .. err)
    end

    local lines = vim.split(str, '\n')
    vim.api.nvim_buf_set_text(buf_id, row, col, row, col, lines)
  end)
end

local function get_prompt(opts)
  local replace = opts.replace
  local visual_lines = M.get_visual_selection()

  if visual_lines then
    -- For visual selection/replace, return a single string
    local prompt_str = table.concat(visual_lines, '\n')
    if replace then
      vim.api.nvim_command 'normal! c'
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', false, true, true), 'nx', false)
    end
    return prompt_str
  else
    -- For normal mode/chat, return the list of lines for parsing
    return M.get_lines_until_cursor()
  end
end

function M.handle_gemini_spec_data(data_stream, buf_id, extmark_id)
  if data_stream:match '"candidates":' then
    local json = vim.json.decode(data_stream)
    if json.candidates and json.candidates[1].content and
        json.candidates[1].content.parts[1].text then
      local content = json.candidates[1].content.parts[1].text
      if content then
        M.write_string_at_extmark(content, buf_id, extmark_id)
      end
    end
  end
end

local group = vim.api.nvim_create_augroup('DING_LLM_AutoGroup', { clear = true })
local active_job = nil

local function debug_write(opts, message)
  if opts.debug and opts.debug_path then
    local debug_file = io.open(opts.debug_path, 'a')
    if debug_file then
      debug_file:write(message .. '\n')
      debug_file:close()
    end
  end
end

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
  vim.api.nvim_clear_autocmds { group = group }

  -- Get prompt (might be string OR table of lines now)
  local prompt_data = get_prompt(opts)

  -- Simple check for empty prompt
  if type(prompt_data) == 'string' and prompt_data == '' then
      vim.notify("Prompt is empty.", vim.log.levels.WARN); return
  elseif type(prompt_data) == 'table' and #prompt_data == 0 then
      vim.notify("Prompt is empty.", vim.log.levels.WARN); return
  end

  local system_prompt = opts.system_prompt or 'You are a helpful assistant.'
  local args, temp_file = make_curl_args_fn(opts, prompt_data, system_prompt)
  if not args then return end

  local curr_event_state = nil
  local buf_id = vim.api.nvim_get_current_buf()
  local crow, _ = unpack(vim.api.nvim_win_get_cursor(0))
  local stream_end_extmark_id = vim.api.nvim_buf_set_extmark(buf_id, ns_id, crow - 1, -1, {})

  -- Status Window Setup
  local status_buf = vim.api.nvim_create_buf(false, true)
  local initial_inner_win_width = 30
  local status_win_opts = {
    relative = "editor", row = 0, col = vim.o.columns - (initial_inner_win_width + 2),
    width = initial_inner_win_width, height = 1, style = "minimal", border = "rounded", focusable = false
  }
  local status_win = vim.api.nvim_open_win(status_buf, false, status_win_opts)
  vim.api.nvim_win_set_option(status_win, 'winhl', 'Normal:NormalFloat,FloatBorder:NormalFloat')

  local function update_floating_window(message)
    vim.schedule(function()
       if not (vim.api.nvim_win_is_valid(status_win) and vim.api.nvim_buf_is_valid(status_buf)) then return end

       vim.api.nvim_buf_set_lines(status_buf, 0, -1, true, { message })

       local new_width = math.max(initial_inner_win_width, vim.fn.strdisplaywidth(message))
       local new_config = {
         relative=status_win_opts.relative, row=status_win_opts.row, height=status_win_opts.height,
         col = vim.o.columns - (new_width + 2), width = new_width
       }
       vim.api.nvim_win_set_config(status_win, new_config)
    end)
  end

  local partial_data = nil
  local function parse_and_call(line)
    local event = line:match '^event: (.+)$'
    if event then
      curr_event_state = event
      partial_data = nil -- Reset partial data on new event
      return
    end

    local data_match = line:match '^data: (.+)$'
    if data_match then
      -- New data line detected.
      -- If we had previous partial data that failed to decode, we drop it here
      -- (standard SSE behavior implies 'data:' is a new block).
      partial_data = data_match
    elseif partial_data then
      -- No 'data:' prefix, but we have partial data waiting.
      -- This line is likely the second half of a split JSON string.
      partial_data = partial_data .. "\n" .. line
    end

    if partial_data then
      -- Try to decode. If it fails, we keep `partial_data` and wait for the next line.
      local success, _ = pcall(vim.json.decode, partial_data)
      if success then
        handle_data_fn(partial_data, buf_id, stream_end_extmark_id, curr_event_state)
        partial_data = nil -- Clear buffer on success
      end
    end
  end

  if active_job then active_job:shutdown(); active_job = nil end

  local curl_cmd_str = table.concat({'curl', unpack(args)}, ' ')
  debug_write(opts, "REQUEST: " .. curl_cmd_str)
  local start_time = vim.loop.hrtime()
  update_floating_window("LLM: Waiting...")

  active_job = Job:new {
    command = 'curl',
    args = args,
    on_stdout = function(_, out)
      parse_and_call(out)
    end,
    on_stderr = function(_, err_line)
       if err_line and err_line:match('^{"error":') then
          local _, err_json = pcall(vim.json.decode, err_line)
          local err_msg = (err_json and err_json.error and err_json.error.message) or err_line
          update_floating_window("API Error: " .. err_msg)
          debug_write(opts, "API ERROR: " .. err_msg)
       end
    end,
    on_exit = function(j, return_val, signal)
      vim.schedule(function()
          if temp_file then os.remove(temp_file) end

          local duration = (vim.loop.hrtime() - start_time) / 1000000
          local msg = (signal and "Aborted") or (return_val ~= 0 and "Error") or "Done"
          msg = string.format("LLM %s [%.0fms]", msg, duration)

          if vim.api.nvim_win_is_valid(status_win) and vim.api.nvim_buf_is_valid(status_buf) then
              vim.api.nvim_buf_set_lines(status_buf, 0, -1, true, { msg })
          end

          -- Cleanup Window after delay
          vim.defer_fn(function()
            if vim.api.nvim_win_is_valid(status_win) then vim.api.nvim_win_close(status_win, true) end
            if vim.api.nvim_buf_is_valid(status_buf) then vim.api.nvim_buf_delete(status_buf, {force=true}) end
          end, 2000)

          -- Cleanup Keymap
          pcall(vim.api.nvim_buf_del_keymap, buf_id, 'n', '<Esc>')

          active_job = nil
      end)
    end,
  }

  active_job:start()

  -- Only cancel the request if Esc is pressed in the prompt buffer.
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'DING_LLM_Escape',
    callback = function()
      if active_job then
        active_job:shutdown()
        active_job = nil
      end
    end,
  })

  vim.api.nvim_buf_set_keymap(buf_id, 'n', '<Esc>', ':doautocmd User DING_LLM_Escape<CR>', { noremap = true, silent = true })

  return active_job
end

return M
