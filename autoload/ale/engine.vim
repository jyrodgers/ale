" Author: w0rp <devw0rp@gmail.com>
" Description: Backend execution and job management
"   Executes linters in the background, using NeoVim or Vim 8 jobs

" Stores information for each job including:
"
" linter: The linter dictionary for the job.
" buffer: The buffer number for the job.
" output: The array of lines for the output of the job.
if !has_key(s:, 'job_info_map')
    let s:job_info_map = {}
endif

" Associates LSP connection IDs with linter names.
if !has_key(s:, 'lsp_linter_map')
    let s:lsp_linter_map = {}
endif

let s:executable_cache_map = {}

" Check if files are executable, and if they are, remember that they are
" for subsequent calls. We'll keep checking until programs can be executed.
function! s:IsExecutable(executable) abort
    if has_key(s:executable_cache_map, a:executable)
        return 1
    endif

    if executable(a:executable)
        let s:executable_cache_map[a:executable] = 1

        return 1
    endif

    return  0
endfunction

function! ale#engine#InitBufferInfo(buffer) abort
    if !has_key(g:ale_buffer_info, a:buffer)
        " job_list will hold the list of job IDs
        " active_linter_list will hold the list of active linter names
        " loclist holds the loclist items after all jobs have completed.
        " temporary_file_list holds temporary files to be cleaned up
        " temporary_directory_list holds temporary directories to be cleaned up
        " history holds a list of previously run commands for this buffer
        let g:ale_buffer_info[a:buffer] = {
        \   'job_list': [],
        \   'active_linter_list': [],
        \   'loclist': [],
        \   'temporary_file_list': [],
        \   'temporary_directory_list': [],
        \   'history': [],
        \}
    endif
endfunction

" Return 1 if ALE is busy checking a given buffer
function! ale#engine#IsCheckingBuffer(buffer) abort
    let l:info = get(g:ale_buffer_info, a:buffer, {})

    return !empty(get(l:info, 'active_linter_list', []))
endfunction

" Register a temporary file to be managed with the ALE engine for
" a current job run.
function! ale#engine#ManageFile(buffer, filename) abort
    call add(g:ale_buffer_info[a:buffer].temporary_file_list, a:filename)
endfunction

" Same as the above, but manage an entire directory.
function! ale#engine#ManageDirectory(buffer, directory) abort
    call add(g:ale_buffer_info[a:buffer].temporary_directory_list, a:directory)
endfunction

" Create a new temporary directory and manage it in one go.
function! ale#engine#CreateDirectory(buffer) abort
    let l:temporary_directory = tempname()
    " Create the temporary directory for the file, unreadable by 'other'
    " users.
    call mkdir(l:temporary_directory, '', 0750)
    call ale#engine#ManageDirectory(a:buffer, l:temporary_directory)

    return l:temporary_directory
endfunction

function! ale#engine#RemoveManagedFiles(buffer) abort
    let l:info = get(g:ale_buffer_info, a:buffer)

    " We can't delete anything in a sandbox, so wait until we escape from
    " it to delete temporary files and directories.
    if ale#util#InSandbox()
        return
    endif

    " Delete files with a call akin to a plan `rm` command.
    if has_key(l:info, 'temporary_file_list')
        for l:filename in l:info.temporary_file_list
            call delete(l:filename)
        endfor

        let l:info.temporary_file_list = []
    endif

    " Delete directories like `rm -rf`.
    " Directories are handled differently from files, so paths that are
    " intended to be single files can be set up for automatic deletion without
    " accidentally deleting entire directories.
    if has_key(l:info, 'temporary_directory_list')
        for l:directory in l:info.temporary_directory_list
            call delete(l:directory, 'rf')
        endfor

        let l:info.temporary_directory_list = []
    endif
endfunction

function! s:GatherOutput(job_id, line) abort
    if has_key(s:job_info_map, a:job_id)
        call add(s:job_info_map[a:job_id].output, a:line)
    endif
endfunction

function! s:HandleLoclist(linter_name, buffer, loclist) abort
    let l:buffer_info = get(g:ale_buffer_info, a:buffer, {})

    if empty(l:buffer_info)
        return
    endif

    " Remove this linter from the list of active linters.
    " This may have already been done when the job exits.
    call filter(l:buffer_info.active_linter_list, 'v:val !=# a:linter_name')

    " Make some adjustments to the loclists to fix common problems, and also
    " to set default values for loclist items.
    let l:linter_loclist = ale#engine#FixLocList(a:buffer, a:linter_name, a:loclist)

    " Remove previous items for this linter.
    call filter(g:ale_buffer_info[a:buffer].loclist, 'v:val.linter_name !=# a:linter_name')
    " Add the new items.
    call extend(g:ale_buffer_info[a:buffer].loclist, l:linter_loclist)

    " Sort the loclist again.
    " We need a sorted list so we can run a binary search against it
    " for efficient lookup of the messages in the cursor handler.
    call sort(g:ale_buffer_info[a:buffer].loclist, 'ale#util#LocItemCompare')

    if ale#ShouldDoNothing(a:buffer)
        return
    endif

    call ale#engine#SetResults(a:buffer, g:ale_buffer_info[a:buffer].loclist)
endfunction

function! s:HandleExit(job_id, exit_code) abort
    if !has_key(s:job_info_map, a:job_id)
        return
    endif

    let l:job_info = s:job_info_map[a:job_id]
    let l:linter = l:job_info.linter
    let l:output = l:job_info.output
    let l:buffer = l:job_info.buffer
    let l:next_chain_index = l:job_info.next_chain_index

    if g:ale_history_enabled
        call ale#history#SetExitCode(l:buffer, a:job_id, a:exit_code)
    endif

    " Remove this job from the list.
    call ale#job#Stop(a:job_id)
    call remove(s:job_info_map, a:job_id)
    call filter(g:ale_buffer_info[l:buffer].job_list, 'v:val !=# a:job_id')
    call filter(g:ale_buffer_info[l:buffer].active_linter_list, 'v:val !=# l:linter.name')

    " Stop here if we land in the handle for a job completing if we're in
    " a sandbox.
    if ale#util#InSandbox()
        return
    endif

    if has('nvim') && !empty(l:output) && empty(l:output[-1])
        call remove(l:output, -1)
    endif

    if l:next_chain_index < len(get(l:linter, 'command_chain', []))
        call s:InvokeChain(l:buffer, l:linter, l:next_chain_index, l:output)
        return
    endif

    " Log the output of the command for ALEInfo if we should.
    if g:ale_history_enabled && g:ale_history_log_output
        call ale#history#RememberOutput(l:buffer, a:job_id, l:output[:])
    endif

    let l:loclist = ale#util#GetFunction(l:linter.callback)(l:buffer, l:output)

    call s:HandleLoclist(l:linter.name, l:buffer, l:loclist)
endfunction

function! s:HandleLSPDiagnostics(conn_id, response) abort
    let l:linter_name = s:lsp_linter_map[a:conn_id]
    let l:filename = ale#path#FromURI(a:response.params.uri)
    let l:buffer = bufnr(l:filename)

    if l:buffer <= 0
        return
    endif

    let l:loclist = ale#lsp#response#ReadDiagnostics(a:response)

    call s:HandleLoclist(l:linter_name, l:buffer, l:loclist)
endfunction

function! s:HandleTSServerDiagnostics(response, error_type) abort
    let l:buffer = bufnr(a:response.body.file)
    let l:info = get(g:ale_buffer_info, l:buffer, {})

    if empty(l:info)
        return
    endif

    let l:thislist = ale#lsp#response#ReadTSServerDiagnostics(a:response)

    " tsserver sends syntax and semantic errors in separate messages, so we
    " have to collect the messages separately for each buffer and join them
    " back together again.
    if a:error_type ==# 'syntax'
        let l:info.syntax_loclist = l:thislist
    else
        let l:info.semantic_loclist = l:thislist
    endif

    let l:loclist = get(l:info, 'semantic_loclist', [])
    \   + get(l:info, 'syntax_loclist', [])

    call s:HandleLoclist('tsserver', l:buffer, l:loclist)
endfunction

function! s:HandleLSPErrorMessage(error_message) abort
    echoerr 'Error from LSP:'

    for l:line in split(a:error_message, "\n")
        echoerr l:line
    endfor
endfunction

function! ale#engine#HandleLSPResponse(conn_id, response) abort
    let l:method = get(a:response, 'method', '')

    if get(a:response, 'jsonrpc', '') ==# '2.0' && has_key(a:response, 'error')
        " Uncomment this line to print LSP error messages.
        " call s:HandleLSPErrorMessage(a:response.error.message)
    elseif l:method ==# 'textDocument/publishDiagnostics'
        call s:HandleLSPDiagnostics(a:conn_id, a:response)
    elseif get(a:response, 'type', '') ==# 'event'
    \&& get(a:response, 'event', '') ==# 'semanticDiag'
        call s:HandleTSServerDiagnostics(a:response, 'semantic')
    elseif get(a:response, 'type', '') ==# 'event'
    \&& get(a:response, 'event', '') ==# 'syntaxDiag'
        call s:HandleTSServerDiagnostics(a:response, 'syntax')
    endif
endfunction

function! ale#engine#SetResults(buffer, loclist) abort
    let l:linting_is_done = !ale#engine#IsCheckingBuffer(a:buffer)

    " Set signs first. This could potentially fix some line numbers.
    " The List could be sorted again here by SetSigns.
    if g:ale_set_signs
        call ale#sign#SetSigns(a:buffer, a:loclist)

        if l:linting_is_done
            call ale#sign#RemoveDummySignIfNeeded(a:buffer)
        endif
    endif

    if g:ale_set_quickfix || g:ale_set_loclist
        call ale#list#SetLists(a:buffer, a:loclist)

        if l:linting_is_done
            call ale#list#CloseWindowIfNeeded(a:buffer)
        endif
    endif

    if exists('*ale#statusline#Update')
        " Don't load/run if not already loaded.
        call ale#statusline#Update(a:buffer, a:loclist)
    endif

    if g:ale_set_highlights
        call ale#highlight#SetHighlights(a:buffer, a:loclist)
    endif

    if g:ale_echo_cursor
        " Try and echo the warning now.
        " This will only do something meaningful if we're in normal mode.
        call ale#cursor#EchoCursorWarning()
    endif

    if l:linting_is_done
        " Automatically remove all managed temporary files and directories
        " now that all jobs have completed.
        call ale#engine#RemoveManagedFiles(a:buffer)

        " Call user autocommands. This allows users to hook into ALE's lint cycle.
        silent doautocmd User ALELint
    endif
endfunction

function! s:RemapItemTypes(type_map, loclist) abort
    for l:item in a:loclist
        let l:key = l:item.type
        \   . (get(l:item, 'sub_type', '') ==# 'style' ? 'S' : '')
        let l:new_key = get(a:type_map, l:key, '')

        if l:new_key ==# 'E'
        \|| l:new_key ==# 'ES'
        \|| l:new_key ==# 'W'
        \|| l:new_key ==# 'WS'
        \|| l:new_key ==# 'I'
            let l:item.type = l:new_key[0]

            if l:new_key ==# 'ES' || l:new_key ==# 'WS'
                let l:item.sub_type = 'style'
            elseif has_key(l:item, 'sub_type')
                call remove(l:item, 'sub_type')
            endif
        endif
    endfor
endfunction

function! ale#engine#FixLocList(buffer, linter_name, loclist) abort
    let l:new_loclist = []

    " Some errors have line numbers beyond the end of the file,
    " so we need to adjust them so they set the error at the last line
    " of the file instead.
    let l:last_line_number = ale#util#GetLineCount(a:buffer)

    for l:old_item in a:loclist
        " Copy the loclist item with some default values and corrections.
        "
        " line and column numbers will be converted to numbers.
        " The buffer will default to the buffer being checked.
        " The vcol setting will default to 0, a byte index.
        " The error type will default to 'E' for errors.
        " The error number will default to -1.
        "
        " The line number and text are the only required keys.
        "
        " The linter_name will be set on the errors so it can be used in
        " output, filtering, etc..
        let l:item = {
        \   'text': l:old_item.text,
        \   'lnum': str2nr(l:old_item.lnum),
        \   'col': str2nr(get(l:old_item, 'col', 0)),
        \   'bufnr': get(l:old_item, 'bufnr', a:buffer),
        \   'vcol': get(l:old_item, 'vcol', 0),
        \   'type': get(l:old_item, 'type', 'E'),
        \   'nr': get(l:old_item, 'nr', -1),
        \   'linter_name': a:linter_name,
        \}

        if has_key(l:old_item, 'detail')
            let l:item.detail = l:old_item.detail
        endif

        " Pass on a end_col key if set, used for highlights.
        if has_key(l:old_item, 'end_col')
            let l:item.end_col = str2nr(l:old_item.end_col)
        endif

        if has_key(l:old_item, 'end_lnum')
            let l:item.end_lnum = str2nr(l:old_item.end_lnum)
        endif

        if has_key(l:old_item, 'sub_type')
            let l:item.sub_type = l:old_item.sub_type
        endif

        if l:item.lnum < 1
            " When errors appear before line 1, put them at line 1.
            let l:item.lnum = 1
        elseif l:item.lnum > l:last_line_number
            " When errors go beyond the end of the file, put them at the end.
            let l:item.lnum = l:last_line_number
        endif

        call add(l:new_loclist, l:item)
    endfor

    let l:type_map = get(ale#Var(a:buffer, 'type_map'), a:linter_name, {})

    if !empty(l:type_map)
        call s:RemapItemTypes(l:type_map, l:new_loclist)
    endif

    return l:new_loclist
endfunction

" Given part of a command, replace any % with %%, so that no characters in
" the string will be replaced with filenames, etc.
function! ale#engine#EscapeCommandPart(command_part) abort
    return substitute(a:command_part, '%', '%%', 'g')
endfunction

function! s:CreateTemporaryFileForJob(buffer, temporary_file) abort
    if empty(a:temporary_file)
        " There is no file, so we didn't create anything.
        return 0
    endif

    let l:temporary_directory = fnamemodify(a:temporary_file, ':h')
    " Create the temporary directory for the file, unreadable by 'other'
    " users.
    call mkdir(l:temporary_directory, '', 0750)
    " Automatically delete the directory later.
    call ale#engine#ManageDirectory(a:buffer, l:temporary_directory)
    " Write the buffer out to a file.
    call writefile(getbufline(a:buffer, 1, '$'), a:temporary_file)

    return 1
endfunction

" Run a job.
"
" Returns 1 when the job was started successfully.
function! s:RunJob(options) abort
    let l:command = a:options.command
    let l:buffer = a:options.buffer
    let l:linter = a:options.linter
    let l:output_stream = a:options.output_stream
    let l:next_chain_index = a:options.next_chain_index
    let l:read_buffer = a:options.read_buffer

    if empty(l:command)
        return 0
    endif

    let [l:temporary_file, l:command] = ale#command#FormatCommand(l:buffer, l:command, l:read_buffer)

    if s:CreateTemporaryFileForJob(l:buffer, l:temporary_file)
        " If a temporary filename has been formatted in to the command, then
        " we do not need to send the Vim buffer to the command.
        let l:read_buffer = 0
    endif

    " Add a newline to commands which need it.
    " This is only used for Flow for now, and is not documented.
    if l:linter.add_newline
        if has('win32')
            let l:command = l:command . '; echo.'
        else
            let l:command = l:command . '; echo'
        endif
    endif

    let l:command = ale#job#PrepareCommand(l:command)
    let l:job_options = {
    \   'mode': 'nl',
    \   'exit_cb': function('s:HandleExit'),
    \}

    if l:output_stream ==# 'stderr'
        let l:job_options.err_cb = function('s:GatherOutput')
    elseif l:output_stream ==# 'both'
        let l:job_options.out_cb = function('s:GatherOutput')
        let l:job_options.err_cb = function('s:GatherOutput')
    else
        let l:job_options.out_cb = function('s:GatherOutput')
    endif

    if get(g:, 'ale_run_synchronously') == 1
        " Find a unique Job value to use, which will be the same as the ID for
        " running commands synchronously. This is only for test code.
        let l:job_id = len(s:job_info_map) + 1

        while has_key(s:job_info_map, l:job_id)
            let l:job_id += 1
        endwhile
    else
        let l:job_id = ale#job#Start(l:command, l:job_options)
    endif

    let l:status = 'failed'

    " Only proceed if the job is being run.
    if l:job_id
        " Add the job to the list of jobs, so we can track them.
        call add(g:ale_buffer_info[l:buffer].job_list, l:job_id)
        call add(g:ale_buffer_info[l:buffer].active_linter_list, l:linter.name)

        let l:status = 'started'
        " Store the ID for the job in the map to read back again.
        let s:job_info_map[l:job_id] = {
        \   'linter': l:linter,
        \   'buffer': l:buffer,
        \   'output': [],
        \   'next_chain_index': l:next_chain_index,
        \}
    endif

    if g:ale_history_enabled
        call ale#history#Add(l:buffer, l:status, l:job_id, l:command)
    else
        let g:ale_buffer_info[l:buffer].history = []
    endif

    if get(g:, 'ale_run_synchronously') == 1
        " Run a command synchronously if this test option is set.
        let s:job_info_map[l:job_id].output = systemlist(
        \   type(l:command) == type([])
        \   ?  join(l:command[0:1]) . ' ' . ale#Escape(l:command[2])
        \   : l:command
        \)

        call l:job_options.exit_cb(l:job_id, v:shell_error)
    endif

    return l:job_id != 0
endfunction

" Determine which commands to run for a link in a command chain, or
" just a regular command.
function! ale#engine#ProcessChain(buffer, linter, chain_index, input) abort
    let l:output_stream = get(a:linter, 'output_stream', 'stdout')
    let l:read_buffer = a:linter.read_buffer
    let l:chain_index = a:chain_index
    let l:input = a:input

    if has_key(a:linter, 'command_chain')
        while l:chain_index < len(a:linter.command_chain)
            " Run a chain of commands, one asychronous command after the other,
            " so that many programs can be run in a sequence.
            let l:chain_item = a:linter.command_chain[l:chain_index]

            if l:chain_index == 0
                " The first callback in the chain takes only a buffer number.
                let l:command = ale#util#GetFunction(l:chain_item.callback)(
                \   a:buffer
                \)
            else
                " The second callback in the chain takes some input too.
                let l:command = ale#util#GetFunction(l:chain_item.callback)(
                \   a:buffer,
                \   l:input
                \)
            endif

            if !empty(l:command)
                " We hit a command to run, so we'll execute that

                " The chain item can override the output_stream option.
                if has_key(l:chain_item, 'output_stream')
                    let l:output_stream = l:chain_item.output_stream
                endif

                " The chain item can override the read_buffer option.
                if has_key(l:chain_item, 'read_buffer')
                    let l:read_buffer = l:chain_item.read_buffer
                elseif l:chain_index != len(a:linter.command_chain) - 1
                    " Don't read the buffer for commands besides the last one
                    " in the chain by default.
                    let l:read_buffer = 0
                endif

                break
            endif

            " Command chain items can return an empty string to indicate that
            " a command should be skipped, so we should try the next item
            " with no input.
            let l:input = []
            let l:chain_index += 1
        endwhile
    else
        let l:command = ale#linter#GetCommand(a:buffer, a:linter)
    endif

    return {
    \   'command': l:command,
    \   'buffer': a:buffer,
    \   'linter': a:linter,
    \   'output_stream': l:output_stream,
    \   'next_chain_index': l:chain_index + 1,
    \   'read_buffer': l:read_buffer,
    \}
endfunction

function! s:InvokeChain(buffer, linter, chain_index, input) abort
    let l:options = ale#engine#ProcessChain(a:buffer, a:linter, a:chain_index, a:input)

    return s:RunJob(l:options)
endfunction

function! s:StopCurrentJobs(buffer, include_lint_file_jobs) abort
    let l:info = get(g:ale_buffer_info, a:buffer, {})
    let l:new_job_list = []

    for l:job_id in get(l:info, 'job_list', [])
        let l:job_info = get(s:job_info_map, l:job_id, {})

        if !empty(l:job_info)
            if a:include_lint_file_jobs || !l:job_info.linter.lint_file
                call ale#job#Stop(l:job_id)
                call remove(s:job_info_map, l:job_id)
            else
                call add(l:new_job_list, l:job_id)
            endif
        endif
    endfor

    " Update the List, so it includes only the jobs we still need.
    let l:info.job_list = l:new_job_list
endfunction

function! s:CheckWithLSP(buffer, linter) abort
    let l:lsp_details = ale#linter#StartLSP(
    \   a:buffer,
    \   a:linter,
    \   function('ale#engine#HandleLSPResponse'),
    \)

    if empty(l:lsp_details)
        return 0
    endif

    let l:id = l:lsp_details.connection_id
    let l:root = l:lsp_details.project_root

    " Remember the linter this connection is for.
    let s:lsp_linter_map[l:id] = a:linter.name

    let l:change_message = a:linter.lsp ==# 'tsserver'
    \   ? ale#lsp#tsserver_message#Geterr(a:buffer)
    \   : ale#lsp#message#DidChange(a:buffer)
    let l:request_id = ale#lsp#Send(l:id, l:change_message, l:root)

    if l:request_id != 0
        call add(g:ale_buffer_info[a:buffer].active_linter_list, a:linter.name)
    endif

    return l:request_id != 0
endfunction

function! s:RemoveProblemsForDisabledLinters(buffer, linters) abort
    " Figure out which linters are still enabled, and remove
    " problems for linters which are no longer enabled.
    let l:name_map = {}

    for l:linter in a:linters
        let l:name_map[l:linter.name] = 1
    endfor

    call filter(
    \   get(g:ale_buffer_info[a:buffer], 'loclist', []),
    \   'get(l:name_map, v:val.linter_name)',
    \)
endfunction

" Run a linter for a buffer.
"
" Returns 1 if the linter was successfully run.
function! s:RunLinter(buffer, linter) abort
    if !empty(a:linter.lsp)
        return s:CheckWithLSP(a:buffer, a:linter)
    else
        let l:executable = ale#linter#GetExecutable(a:buffer, a:linter)

        if s:IsExecutable(l:executable)
            return s:InvokeChain(a:buffer, a:linter, 0, [])
        endif
    endif

    return 0
endfunction

function! ale#engine#RunLinters(buffer, linters, should_lint_file) abort
    " Initialise the buffer information if needed.
    call ale#engine#InitBufferInfo(a:buffer)
    call s:StopCurrentJobs(a:buffer, a:should_lint_file)
    call s:RemoveProblemsForDisabledLinters(a:buffer, a:linters)

    " We can only clear the results if we aren't checking the buffer.
    let l:can_clear_results = !ale#engine#IsCheckingBuffer(a:buffer)

    for l:linter in a:linters
        " Only run lint_file linters if we should.
        if !l:linter.lint_file || a:should_lint_file
            if s:RunLinter(a:buffer, l:linter)
                " If a single linter ran, we shouldn't clear everything.
                let l:can_clear_results = 0
            endif
        else
            " If we skipped running a lint_file linter still in the list,
            " we shouldn't clear everything.
            let l:can_clear_results = 0
        endif
    endfor

    " Clear the results if we can. This needs to be done when linters are
    " disabled, or ALE itself is disabled.
    if l:can_clear_results
        call ale#engine#SetResults(a:buffer, [])
    endif
endfunction

" Clean up a buffer.
"
" This function will stop all current jobs for the buffer,
" clear the state of everything, and remove the Dictionary for managing
" the buffer.
function! ale#engine#Cleanup(buffer) abort
    if !has_key(g:ale_buffer_info, a:buffer)
        return
    endif

    call ale#engine#RunLinters(a:buffer, [], 1)

    call remove(g:ale_buffer_info, a:buffer)
endfunction

" Given a buffer number, return the warnings and errors for a given buffer.
function! ale#engine#GetLoclist(buffer) abort
    if !has_key(g:ale_buffer_info, a:buffer)
        return []
    endif

    return g:ale_buffer_info[a:buffer].loclist
endfunction

" This function can be called with a timeout to wait for all jobs to finish.
" If the jobs to not finish in the given number of milliseconds,
" an exception will be thrown.
"
" The time taken will be a very rough approximation, and more time may be
" permitted than is specified.
function! ale#engine#WaitForJobs(deadline) abort
    let l:start_time = ale#util#ClockMilliseconds()

    if l:start_time == 0
        throw 'Failed to read milliseconds from the clock!'
    endif

    let l:job_list = []

    " Gather all of the jobs from every buffer.
    for l:info in values(g:ale_buffer_info)
        call extend(l:job_list, l:info.job_list)
    endfor

    " NeoVim has a built-in API for this, so use that.
    if has('nvim')
        let l:nvim_code_list = jobwait(l:job_list, a:deadline)

        if index(l:nvim_code_list, -1) >= 0
            throw 'Jobs did not complete on time!'
        endif

        return
    endif

    let l:should_wait_more = 1

    while l:should_wait_more
        let l:should_wait_more = 0

        for l:job_id in l:job_list
            if ale#job#IsRunning(l:job_id)
                let l:now = ale#util#ClockMilliseconds()

                if l:now - l:start_time > a:deadline
                    " Stop waiting after a timeout, so we don't wait forever.
                    throw 'Jobs did not complete on time!'
                endif

                " Wait another 10 milliseconds
                let l:should_wait_more = 1
                sleep 10ms
                break
            endif
        endfor
    endwhile

    " Sleep for a small amount of time after all jobs finish.
    " This seems to be enough to let handlers after jobs end run, and
    " prevents the occasional failure where this function exits after jobs
    " end, but before handlers are run.
    sleep 10ms

    " We must check the buffer data again to see if new jobs started
    " for command_chain linters.
    let l:has_new_jobs = 0

    " Check again to see if any jobs are running.
    for l:info in values(g:ale_buffer_info)
        for l:job_id in l:info.job_list
            if ale#job#IsRunning(l:job_id)
                let l:has_new_jobs = 1
                break
            endif
        endfor
    endfor

    if l:has_new_jobs
        " We have to wait more. Offset the timeout by the time taken so far.
        let l:now = ale#util#ClockMilliseconds()
        let l:new_deadline = a:deadline - (l:now - l:start_time)

        if l:new_deadline <= 0
            " Enough time passed already, so stop immediately.
            throw 'Jobs did not complete on time!'
        endif

        call ale#engine#WaitForJobs(l:new_deadline)
    endif
endfunction
