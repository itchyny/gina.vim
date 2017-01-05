let s:Argument = vital#gina#import('Argument')
let s:Console = vital#gina#import('Vim.Console')
let s:Emitter = vital#gina#import('Emitter')
let s:Exception = vital#gina#import('Vim.Exception')
let s:Git = vital#gina#import('Git')

let s:SCISSOR = '------------------------ >8 ------------------------'
let s:messages = {}


function! gina#command#commit#command(range, qargs, qmods) abort
  let git = gina#core#get_or_fail()
  let args = s:build_args(a:qargs)
  let bufname = printf(
        \ 'gina:%s:commit',
        \ git.refname,
        \)
  call gina#util#buffer#open(bufname, {
        \ 'group': 'quick',
        \ 'opener': args.params.opener,
        \ 'callback': {
        \   'fn': function('s:init'),
        \   'args': [args],
        \ }
        \})
endfunction


" Private --------------------------------------------------------------------
function! s:build_args(qargs) abort
  let args = s:Argument.new(a:qargs)
  let args.params.amend = args.get('--amend')
  let args.params.opener = args.get('--opener', 'edit')
  return args.lock()
endfunction

function! s:init(args) abort
  call gina#util#meta#set('args', a:args)

  if exists('b:gina_initialized')
    return
  endif
  let b:gina_initialized = 1

  setlocal nobuflisted
  setlocal buftype=acwrite
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal modifiable

  augroup gina_internal_command
    autocmd! * <buffer>
    autocmd BufReadCmd <buffer> call s:BufReadCmd()
    autocmd BufWriteCmd <buffer> call s:BufWriteCmd()
    autocmd WinLeave <buffer> call s:WinLeave()
    autocmd WinEnter * call s:WinEnter()
  augroup END

  nnoremap <silent><buffer>
        \ <Plug>(gina-commit-status)
        \ :<C-u>Gina status<CR>
  nnoremap <silent><buffer>
        \ <Plug>(gina-commit-toggle-amend)
        \ :<C-u>call <SID>toggle_amend()<CR>
endfunction

function! s:BufReadCmd() abort
  let git = gina#core#get_or_fail()
  let args = gina#util#meta#get_or_fail('args')
  let content = s:Exception.call(
        \ function('s:get_commitmsg'),
        \ [git, args]
        \)
  call gina#util#buffer#content(content)
  setlocal filetype=gina-commit
endfunction

function! s:BufWriteCmd() abort
  let git = gina#core#get_or_fail()
  let args = gina#util#meta#get_or_fail('args')
  call s:Exception.call(
        \ function('s:set_commitmsg'),
        \ [git, args, getline(1, '$')]
        \)
  setlocal nomodified
endfunction

function! s:WinLeave() abort
  let s:params_on_winleave = {
        \ 'git': gina#core#get_or_fail(),
        \ 'args': gina#util#meta#get_or_fail('args'),
        \ 'nwin': winnr('$'),
        \}
endfunction

function! s:WinEnter() abort
  if exists('s:params_on_winleave')
    if winnr('$') < s:params_on_winleave.nwin
      call s:Exception.call(
            \ function('s:commit_commitmsg_confirm'),
            \ [s:params_on_winleave.git, s:params_on_winleave.args]
            \)
    endif
    unlet s:params_on_winleave
  endif
endfunction

function! s:toggle_amend() abort
  let args = gina#util#meta#get_or_fail('args')
  let args = args.clone()
  if args.get('--amend')
    call args.pop('--amend')
  else
    call args.set('--amend', 1)
  endif
  call gina#util#meta#set('args', args)
  edit
endfunction

function! s:get_commitmsg(git, args) abort
  let args = a:args.clone()
  let cname = args.get('--amend') ? 'amend' : '_'
  let cache = s:get_cached_commitmsg(a:git, cname)

  let tempfile = tempname()
  try
    if !empty(cache)
      call writefile(cache, tempfile)
      call args.set('-F|--file', tempfile)
      call args.pop('-C|--reuse-message')
      call args.pop('-m|--message')
    endif

    let result = gina#util#process#call(a:git, args.raw)
    if !result.status
      " NOTE: Operation should be fail while GIT_EDITOR=false
      throw gina#util#process#error(result)
    endif
    return s:get_config_commitmsg(a:git)
  finally
    call delete(tempfile)
  endtry
endfunction

function! s:set_commitmsg(git, args, content) abort
  let args = a:args.clone()
  let cname = args.get('--amend') ? 'amend' : '_'
  let commitmsg = s:cleanup_commitmsg(
        \ a:git,
        \ a:content,
        \ args.get('--cleanup', args.get('--verbose') ? 'scissors' : 'strip'),
        \)
  call s:set_config_commitmsg(a:git, a:content)
  call s:set_cached_commitmsg(a:git, cname, a:content)
endfunction

function! s:commit_commitmsg(git, args) abort
  let args = a:args.clone()
  let content = s:cleanup_commitmsg(
        \ a:git,
        \ s:get_config_commitmsg(a:git),
        \ args.get('--cleanup', args.get('--verbose') ? 'scissors' : 'strip'),
        \)
  let tempfile = tempname()
  try
    call writefile(content, tempfile)
    call args.set('--no-edit', 1)
    call args.set('-F|--file', tempfile)
    call args.pop('-C|--reuse-message')
    call args.pop('-m|--message')
    call args.pop('-e|--edit')
    let result = gina#util#process#call(a:git, args.raw)
    call s:Emitter.emit('gina:modified')
    call s:remove_cached_commitmsg(a:git)
    if result.status
      throw gina#util#process#error(result)
    endif
    execute 'Gina status'
  finally
    call delete(tempfile)
  endtry
endfunction

function! s:commit_commitmsg_confirm(git, args) abort
  if s:Console.confirm('Do you want to commit changes?', 'y')
    call s:commit_commitmsg(a:git, a:args)
  else
    redraw | echo ''
  endif
endfunction

function! s:cleanup_commitmsg(git, content, mode, ...) abort
  " XXX: Read comment char from config
  let comment = get(a:000, 0, '#')
  let content = copy(a:content)
  if a:mode =~# '^\%(default\|strip\|whitespace\|scissors\)$'
    " Strip leading and trailing empty lines
    let content = split(
          \ substitute(join(content, "\n"), '^\n\+\|\n\+$', '', 'g'),
          \ "\n"
          \)
    " Strip trailing whitespace
    call map(content, 'substitute(v:val, ''\s\+$'', '''', '''')')
    " Remove content after a scissor
    if a:mode =~# '^\%(scissors\)$'
      let scissor = index(content, printf('%s %s', comment, s:SCISSOR))
      let content = scissor == -1 ? content : content[:scissor]
    endif
    " Strip commentary
    if a:mode =~# '^\%(default\|strip\|scissors\)$'
      call map(content, printf('v:val =~# ''^%s'' ? '''' : v:val', comment))
    endif
    " Collapse consecutive empty lines
    let indices = range(len(content))
    let status = ''
    for index in reverse(indices)
      if empty(content[index]) && status ==# 'consecutive'
        call remove(content, index)
      else
        let status = empty(content[index]) ? 'consecutive' : ''
      endif
    endfor
  endif
  return content
endfunction

function! s:get_config_commitmsg(git) abort
  let path = s:Git.resolve(a:git, 'COMMIT_EDITMSG')
  return readfile(path)
endfunction

function! s:set_config_commitmsg(git, content) abort
  let path = s:Git.resolve(a:git, 'COMMIT_EDITMSG')
  return writefile(a:content, path)
endfunction

function! s:get_cached_commitmsg(git, name) abort
  let cname = a:git.worktree
  let s:messages[cname] = get(s:messages, cname, {})
  return get(s:messages[cname], a:name, [])
endfunction

function! s:set_cached_commitmsg(git, name, content) abort
  let cname = a:git.worktree
  let s:messages[cname] = get(s:messages, cname, {})
  let s:messages[cname][a:name] = a:content
endfunction

function! s:remove_cached_commitmsg(git) abort
  let cname = a:git.worktree
  let s:messages[cname] = {}
endfunction
