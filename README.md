
### dingllm.nvim

My modified version of yacineMTB's [dingllm.nvim](https://github.com/yacineMTB/dingllm.nvim).

https://github.com/user-attachments/assets/5a840f01-f5ae-41f9-b59f-365e924e1da8

How I use it:

* `<leader>k` - replace code in visual selection, following code comments.
* `<leader>K` - read lines in buffer above cursor, answering questions.

### lazy config
Add your API keys to your env (export it in zshrc or bashrc) 

```lua
    {
        'spenserlee/dingllm.nvim',
        dependencies = { 'nvim-lua/plenary.nvim' },
        config = function()
            local system_prompt = [[
            You are an AI programming assistant integrated into a code editor. Your purpose is to help the user with programming tasks as they write code or answer questions.
            Key capabilities:
            - Thoroughly analyze the user's code and provide insightful suggestions for improvements related to best practices, performance, readability, and maintainability. Explain your reasoning.
            - Answer coding questions in detail, using examples from the user's own code when relevant. Break down complex topics step- Spot potential bugs and logical errors. Alert the user and suggest fixes.
            - Upon request, add helpful comments explaining complex or unclear code.
            - Suggest relevant documentation, StackOverflow answers, and other resources related to the user's code and questions.
            - Engage in back-and-forth conversations to understand the user's intent and provide the most helpful information.
            - Consider other possibilities to achieve the result, do not be limited by the prompt.
            - Keep concise and use markdown.
            - When asked to create code, only generate the code. No bugs.
            - Think step by step.
            ]]

            local replace_prompt = [[
            You are an AI programming assistant integrated into a code editor.
            Follow the instructions in the code comments.
            Generate code only.
            Do not output markdown backticks like this ```.
            Think step by step.
            If you must speak, do so in comments.
            Generate valid code only.
            ]]

            local dingllm = require('dingllm')
            local release_url = 'https://generativelanguage.googleapis.com/v1/models'
            -- local g_model = 'gemini-1.5-flash'
            -- local g_model = 'gemini-1.5-pro'
            local beta_url = 'https://generativelanguage.googleapis.com/v1beta/models'
            -- local g_model = 'gemini-exp-1206'
            local g_model = 'gemini-2.0-flash-exp'
            local debug_path = '/tmp/dingllm_debug.log'

            local function gemeni_replace()
                if not confirm_action("Proceed with LLM 'replace' operation?") then
                    print("LLM 'replace' cancelled.")
                    return
                end
                dingllm.invoke_llm_and_stream_into_editor({
                    url = beta_url,
                    model = g_model,
                    api_key_name = 'GEMINI_API_KEY',
                    system_prompt = replace_prompt,
                    replace = true,
                    debug = false,
                    debug_path = debug_path,
                }, dingllm.make_gemini_spec_curl_args, dingllm.handle_gemini_spec_data)
            end

            local function gemeni_help()
                if not confirm_action("Proceed with LLM 'help' operation?") then
                    print("LLM 'help' cancelled.")
                    return
                end

                -- Optional: Automatically insert a separator so the LLM knows you are finished typing
                -- This helps the "parse_gemini_history" function.
                local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
                vim.api.nvim_buf_set_lines(0, row, row, false, { "", "## Model", "" })
                vim.api.nvim_win_set_cursor(0, { row + 3, 0 })

                dingllm.invoke_llm_and_stream_into_editor({
                    url = beta_url,
                    model = g_model,
                    api_key_name = 'GEMINI_API_KEY',
                    system_prompt = system_prompt,
                    replace = false,
                    debug = false,
                    debug_path = debug_path,
                }, dingllm.make_gemini_spec_curl_args, dingllm.handle_gemini_spec_data)
            end

            vim.keymap.set({ 'n', 'v' }, '<leader>k', gemeni_replace, { desc = 'llm gemeni' })
            vim.keymap.set({ 'n', 'v' }, '<leader>K', gemeni_help, { desc = 'llm gemeni_help' })
        end,
    },
```

### Credits
This extension woudln't exist if it weren't for https://github.com/melbaldove/llm.nvim

