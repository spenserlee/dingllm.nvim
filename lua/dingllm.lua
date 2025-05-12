local M = {}
local Job = require 'plenary.job'
local ns_id = vim.api.nvim_create_namespace 'dingllm'

local function get_api_key(name)
  return os.getenv(name)
end

function M.get_lines_until_cursor()
  local current_buffer = vim.api.nvim_get_current_buf()
  local current_window = vim.api.nvim_get_current_win()
  local cursor_position = vim.api.nvim_win_get_cursor(current_window)
  local row = cursor_position[1]

  local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

  return table.concat(lines, '\n')
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

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
  local url = opts.url
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local data = {
    system = system_prompt,
    messages = { { role = 'user', content = prompt } },
    model = opts.model,
    stream = true,
    max_tokens = 4096,
  }

  -- Create a temporary file and write JSON data
  local temp_file = vim.fn.tempname()
  local file, err = io.open(temp_file, "w")
  if not file then
    print("Error creating temporary file: " .. err)
    return nil, nil
  end
  local success, write_err = pcall(function() file:write(vim.json.encode(data)) end)
  if not success then
    print("Error writing to temporary file: " .. write_err)
    file:close()
    vim.fn.delete(temp_file)
    return nil, nil
  end
  file:close()

  -- Use --data-binary to read from the file
  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', '@' .. temp_file }
  if api_key then
    table.insert(args, '-H')
    table.insert(args, 'x-api-key: ' .. api_key)
    table.insert(args, '-H')
    table.insert(args, 'anthropic-version: 2023-06-01')
  end
  table.insert(args, url)
  return args, temp_file
end

function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
  local url = opts.url
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local data = {
    messages = { { role = 'system', content = system_prompt }, { role = 'user', content = prompt } },
    model = opts.model,
    temperature = 0.7,
    stream = true,
  }

  -- Create a temporary file and write JSON data
  local temp_file = vim.fn.tempname()
  local file, err = io.open(temp_file, "w")
  if not file then
    print("Error creating temporary file: " .. err)
    return nil, nil
  end
  local success, write_err = pcall(function() file:write(vim.json.encode(data)) end)
  if not success then
    print("Error writing to temporary file: " .. write_err)
    file:close()
    vim.fn.delete(temp_file)
    return nil, nil
  end
  file:close()

  -- Use --data-binary to read from the file
  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', '@' .. temp_file }
  if api_key then
    table.insert(args, '-H')
    table.insert(args, 'Authorization: Bearer ' .. api_key)
  end
  table.insert(args, url)
  return args, temp_file
end

function M.make_gemini_spec_curl_args(opts, prompt, system_prompt)
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local url = opts.url .. "/" .. opts.model .. ":streamGenerateContent?alt=sse&key=" .. api_key

  local data = {
    contents = {
      {
        role = "user",
        parts = { { text = prompt } },
      },
    },
  }
  if system_prompt and system_prompt ~= "" then
    data.systemInstruction = {
      parts = { { text = system_prompt } },
    }
  end

  -- Create a temporary file and write JSON data
  local temp_file = vim.fn.tempname()
  local file, err = io.open(temp_file, "w")
  if not file then
    print("Error creating temporary file: " .. err)
    return nil, nil
  end
  local success, write_err = pcall(function() file:write(vim.json.encode(data)) end)
  if not success then
    print("Error writing to temporary file: " .. write_err)
    file:close()
    vim.fn.delete(temp_file)
    return nil, nil
  end
  file:close()

  -- Use --data-binary to read from the file
  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', '@' .. temp_file }
  table.insert(args, url)
  return args, temp_file
end

function M.write_string_at_extmark(str, buf_id, extmark_id)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf_id) then
      return
    end

    local extmark = vim.api.nvim_buf_get_extmark_by_id(buf_id, ns_id, extmark_id, { details = false })
    if not extmark then
      return
    end
    local row, col = extmark[1], extmark[2]

    local success, err = pcall(vim.cmd, 'undojoin')
    if not success then
      if err:match 'E790' then
        print("Undojoin failed with E790, ignored")
      else
        print("Unexpected error...")
      end
    end

    local lines = vim.split(str, '\n')
    vim.api.nvim_buf_set_text(buf_id, row, col, row, col, lines)
  end)
end

local function get_prompt(opts)
  local replace = opts.replace
  local visual_lines = M.get_visual_selection()
  local prompt = ''

  if visual_lines then
    prompt = table.concat(visual_lines, '\n')
    if replace then
      vim.api.nvim_command 'normal! c'
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', false, true, true), 'nx', false)
    end
  else
    prompt = M.get_lines_until_cursor()
  end

  return prompt
end

function M.handle_anthropic_spec_data(data_stream, buf_id, extmark_id, event_state)
  if event_state == 'content_block_delta' then
    local json = vim.json.decode(data_stream)
    if json.delta and json.delta.text then
      M.write_string_at_extmark(json.delta.text, buf_id, extmark_id)
    end
  end
end

function M.handle_openai_spec_data(data_stream, buf_id, extmark_id)
  if data_stream:match '"delta":' then
    local json = vim.json.decode(data_stream)
    if json.choices and json.choices[1] and json.choices[1].delta then
      local content = json.choices[1].delta.content
      if content then
        M.write_string_at_extmark(content, buf_id, extmark_id)
      end
    end
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
    else
      print("Error: Could not open debug log file at path: " .. opts.debug_path)
    end
  end
end

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
  vim.api.nvim_clear_autocmds { group = group }
  local prompt = get_prompt(opts)
  if prompt == '' then
      vim.notify("dingllm: Prompt is empty. Aborting.", vim.log.levels.WARN)
      return
  end

  local system_prompt = opts.system_prompt or 'You are a helpful assistant.' -- Sensible default
  local args, temp_file = make_curl_args_fn(opts, prompt, system_prompt)
  if not args then
    return
  end

  local curr_event_state = nil
  local buf_id = vim.api.nvim_get_current_buf()
  local crow, _ = unpack(vim.api.nvim_win_get_cursor(0))
  local stream_end_extmark_id = vim.api.nvim_buf_set_extmark(buf_id, ns_id, crow - 1, -1, {})

  -- Setup floating window
  local status_buf = vim.api.nvim_create_buf(false, true)
  -- These are INNER dimensions for content, when border is present
  local initial_inner_win_width = 30
  local initial_inner_win_height = 1

  local status_win_opts = {
    relative = "editor",
    row = 0,
    -- Total width = inner_width + 2 (for left/right border parts)
    col = vim.o.columns - (initial_inner_win_width + 2),
    width = initial_inner_win_width,   -- Inner width
    height = initial_inner_win_height, -- Inner height
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
  }
  local status_win = vim.api.nvim_open_win(status_buf, false, status_win_opts)
  vim.api.nvim_win_set_option(status_win, 'winhl', 'Normal:NormalFloat,FloatBorder:NormalFloat')

  local function update_floating_window(message)
    if vim.api.nvim_win_is_valid(status_win) and vim.api.nvim_buf_is_valid(status_buf) then
      vim.schedule(function() -- Deferring UI updates to the main loop is safer
        if not (vim.api.nvim_win_is_valid(status_win) and vim.api.nvim_buf_is_valid(status_buf)) then return end

        vim.api.nvim_buf_set_lines(status_buf, 0, -1, true, { message })

        local message_text_width = vim.fn.strdisplaywidth(message)
        -- New inner width is the max of initial inner width and current message text width
        local new_inner_width = math.max(initial_inner_win_width, message_text_width)

        local new_config = {
          relative = status_win_opts.relative, -- Must re-specify "relative"
          row = status_win_opts.row,           -- Keep original row
          col = vim.o.columns - (new_inner_width + 2), -- Recalculate col based on new total width
          width = new_inner_width,             -- Set new inner width
          height = status_win_opts.height,     -- Keep original inner height
        }
        vim.api.nvim_win_set_config(status_win, new_config)
      end)
    end
  end

  local function parse_and_call(line)
    local event = line:match '^event: (.+)$'
    if event then
      curr_event_state = event
      return
    end
    local data_match = line:match '^data: (.+)$'
    if data_match then
      handle_data_fn(data_match, buf_id, stream_end_extmark_id, curr_event_state)
    end
  end

  if active_job then
    active_job:shutdown()
    active_job = nil
  end

  local curl_command = table.concat({'curl', unpack(args)}, ' ')
  debug_write(opts, "REQUEST: " .. curl_command .. " (temp_file: " .. temp_file .. ")")

  local start_time = vim.loop.hrtime()
  update_floating_window("LLM: Waiting...")

  active_job = Job:new {
    command = 'curl',
    args = args,
    on_stdout = function(_, out)
      parse_and_call(out)
      debug_write(opts, '\nRESPONSE: on_stdout: ' .. out)
    end,
    on_stderr = function(_, err_line)
      if err_line == nil or err_line == "" then return end -- Ignore empty lines from stderr
      -- Curl progress often goes to stderr. You might want to parse it.
      -- For now, just log it.
      debug_write(opts, 'RESPONSE STDERR: ' .. err_line)
      -- Potentially update status window with stderr info if it's not progress
      if not err_line:match('^%s*%%') and not err_line:match('^{"error":') then -- filter curl progress
          -- Show first few critical errors, not all stderr
          -- update_floating_window("LLM stderr: " .. err_line)
      end
      if err_line:match('^{"error":') then -- JSON error from API
          local _, err_json = pcall(vim.json.decode, err_line)
          if err_json and err_json.error and err_json.error.message then
              update_floating_window("LLM API Error: " .. err_json.error.message)
          else
              update_floating_window("LLM API Error (raw): " .. err_line)
          end
          if temp_file then
              local success, err = pcall(os.remove, temp_file)
              if not success then
                  print("Error deleting temporary file: " .. err)
              end
          end
      end
    end,
    on_exit = function(j, return_val, signal)
      if temp_file then
          local success, err = pcall(os.remove, temp_file)
          if not success then
              print("Error deleting temporary file: " .. err)
          end
      end

      local end_time = vim.loop.hrtime()
      local elapsed_time_ms = (end_time - start_time) / 1000000

      local final_message
      if signal then -- Job was killed by a signal
          final_message = string.format("LLM Aborted (sig: %s) [%.0fms]", tostring(signal), elapsed_time_ms)
          -- If job was manually shut down, `active_job` might be nil here if callback sequence is tricky
          -- Check `j:is_shutdown_called()` if Plenary supports it, or a flag.
      elseif return_val ~= 0 then
        final_message = string.format("LLM Error (code: %s) [%.0fms]", tostring(return_val), elapsed_time_ms)
      else
        final_message = string.format("LLM Done [%.0fms]", elapsed_time_ms)
      end

      vim.schedule(function() update_floating_window(final_message) end)

      -- Full response logging (might be very large)
      -- local full_stdout = table.concat(j:result() or {}, '\n')
      -- debug_write(opts, '\nRESPONSE full stdout (ret=' .. tostring(return_val) .. ', sig='..tostring(signal)..'):\n' .. full_stdout)
      -- local full_stderr = table.concat(j:stderr_result() or {}, '\n')
      -- debug_write(opts, '\nRESPONSE full stderr:\n' .. full_stderr)

      vim.defer_fn(function()
        if vim.api.nvim_win_is_valid(status_win) then
          vim.api.nvim_win_close(status_win, true)
        end
        if vim.api.nvim_buf_is_valid(status_buf) then
            vim.api.nvim_buf_delete(status_buf, {force = true})
        end
      end, 2750)
      active_job = nil
    end,
  }

  active_job:start()

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DING_LLM_Escape',
    callback = function()
      if active_job then
        vim.notify("dingllm: Cancelling LLM stream...", vim.log.levels.INFO, {title="DingLLM"})
        active_job:shutdown() -- This will trigger on_exit with a signal
        -- on_exit will handle updating the window and cleaning up.
        -- update_floating_window("LLM: Cancelling...") -- on_exit will show final status
        active_job = nil -- Mark as inactive immediately
      end
    end,
  })

  vim.api.nvim_set_keymap('n', '<Esc>', ':doautocmd User DING_LLM_Escape<CR>', { noremap = true, silent = true })
  return active_job
end

return M
