function! s:on_response(on_completions, conn_id, response) abort
  if !s:is_completion_valid(get(a:response, 'id'))
    return
  endif

  let completions = ale#completion#ParseLSPCompletions(a:response)
  call a:on_completions(completions)
endfunction

function! s:on_tsserver_response(on_completions, conn_id, response) abort

    if !s:is_completion_valid(get(a:response, 'request_seq'))
        return
    endif

    if !has_key(a:response, 'body')
        return
    endif

    let l:buffer = bufnr('')
    let l:command = get(a:response, 'command', '')

    if l:command is# 'completions'
        let l:names = ale#completion#Filter(
        \   l:buffer,
        \   &filetype,
        \   ale#completion#ParseTSServerCompletions(a:response),
        \   b:ale_completion_info.prefix,
        \)[: g:ale_completion_max_suggestions - 1]

        " We need to remember some names for tsserver, as it doesn't send
        " details back for everything we send.
        call setbufvar(l:buffer, 'ale_tsserver_completion_names', l:names)

        if !empty(l:names)
            let b:ale_completion_info.request_id = ale#lsp#Send(
            \   b:ale_completion_info.conn_id,
            \   ale#lsp#tsserver_message#CompletionEntryDetails(
            \       l:buffer,
            \       b:ale_completion_info.line,
            \       b:ale_completion_info.column,
            \       l:names,
            \   ),
            \)
        endif
    elseif l:command is# 'completionEntryDetails'
      let completions = ale#completion#ParseTSServerCompletionEntryDetails(a:response)
      call a:on_completions(completions)
    endif
endfunction

function! s:OnReady(F, linter, lsp_details) abort
  let l:id = a:lsp_details.connection_id

  if !ale#lsp#HasCapability(l:id, 'completion')
      return
  endif

  " If we have sent a completion request already, don't send another.
  if b:ale_completion_info.request_id
      return
  endif

  let l:id = a:lsp_details.connection_id

  if !ale#lsp#HasCapability(l:id, 'completion')
      return
  endif

  let l:buffer = a:lsp_details.buffer
  let l:id = a:lsp_details.connection_id
  let l:root = a:lsp_details.project_root

  let l:Callback = a:linter.lsp is# 'tsserver'
  \   ? function('s:on_tsserver_response', [a:F])
  \   : function('s:on_response', [a:F])
  call ale#lsp#RegisterCallback(l:id, l:Callback)

  if a:linter.lsp is# 'tsserver'
    let l:message = ale#lsp#tsserver_message#Completions(
    \   l:buffer,
    \   b:ale_completion_info.line,
    \   b:ale_completion_info.column,
    \   b:ale_completion_info.prefix,
    \)
  else
    " Send a message saying the buffer has changed first, otherwise
    " completions won't know what text is nearby.
    call ale#lsp#NotifyForChanges(l:id, l:root, l:buffer)

    " For LSP completions, we need to clamp the column to the length of
    " the line. python-language-server and perhaps others do not implement
    " this correctly.
    let l:message = ale#lsp#message#Completion(
    \   l:buffer,
    \   b:ale_completion_info.line,
    \   min([
    \       b:ale_completion_info.line_length,
    \       b:ale_completion_info.column,
    \   ]),
    \   ale#completion#GetTriggerCharacter(&filetype, b:ale_completion_info.prefix),
    \)
  endif

  let l:request_id = ale#lsp#Send(l:id, l:message)

  if l:request_id
    let b:ale_completion_info.conn_id = l:id
    let b:ale_completion_info.request_id = l:request_id

    if has_key(a:linter, 'completion_filter')
        let b:ale_completion_info.completion_filter = a:linter.completion_filter
    endif
  endif
endfunction

function! s:is_completion_valid(request_id) abort
    let [l:line, l:column] = getcurpos()[1:2]

    return ale#util#Mode() is# 'i'
    \&& has_key(b:, 'ale_completion_info')
    \&& b:ale_completion_info.request_id == a:request_id
    \&& b:ale_completion_info.line == l:line
    \&& b:ale_completion_info.column == l:column
endfunction

function! s:request_completions(ctx, linter, F) abort
  let l:OnReady = function('s:OnReady', [a:F])
  call ale#lsp_linter#StartLSP(a:ctx.bufnr, a:linter, l:OnReady)
endfunction

function! s:completor(linter, opt, ctx) abort
  let l:kw = matchstr(a:ctx.typed, '\w\+$')
  let l:kwlen = len(l:kw)
  let l:startcol = a:ctx.col - l:kwlen
  let l:prefix = ale#completion#GetPrefix(&filetype, a:ctx.lnum, a:ctx.col)
  let b:ale_completion_info = {
  \   'line': a:ctx.lnum,
  \   'line_length': 1000,
  \   'column': a:ctx.col,
  \   'prefix': prefix,
  \   'conn_id': 0,
  \   'request_id': 0,
  \}

  call s:request_completions(a:ctx, a:linter, {completions ->
    \ asyncomplete#complete(a:opt.name, a:ctx, l:startcol, completions)
    \ })
endfunction

function! s:get_linter(name) abort
  let linters = ale#linter#GetLintersLoaded()
  let whitelist = []
  let found = v:null

  for filetype in keys(linters)
    for linter in linters[filetype]
      if linter.name ==# a:name
        call add(whitelist, filetype)
        let found = linter
      endif
    endfor
  endfor

  return {'linter': found, 'whitelist': whitelist}
endfunction

function! asyncomplete#ale#register_source(opt) abort
  let info = s:get_linter(a:opt.linter)
  if type(info.linter) == v:null
    echoerr "No ALE linter '" . a:opt.linter . "' found."
  else
    call asyncomplete#register_source({
        \ 'name': a:opt.name,
        \ 'whitelist': info.whitelist,
        \ 'priority': get(a:opt, 'priority', 5),
        \ 'completor': function('s:completor', [info.linter]),
        \ })
  endif
endfunction
