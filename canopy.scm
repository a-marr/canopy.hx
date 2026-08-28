(require "helix/components.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require "helix/ext.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require "notify/notify.scm")
(require "glyph/glyph.scm")
(require "devicons/devicons.scm")

;; file icons come from devicons (nvim-tree catalog, the grove look);
;; directories and git badges stay on glyph
(define (canopy-hex2 n)
  (define s (number->string n 16))
  (if (< (string-length s) 2) (string-append "0" s) s))

(define (canopy-file-icon name)
  (define ic (get_icon name))
  (if ic (icon-glyph ic) (glyph-icon name)))

(define (canopy-file-color name)
  (define ic (get_icon name))
  (if ic
      (string-append "#" (canopy-hex2 (icon-red ic))
                     (canopy-hex2 (icon-green ic))
                     (canopy-hex2 (icon-blue ic)))
      (glyph-color name)))

(define (canopy-info msg)
  (notify msg #:title "canopy.hx"))

(define (canopy-error msg)
  (notify msg #:severity 'error #:title "canopy.hx"))

(define *canopy-width* 32)
(define *canopy-min-width* 16)
(define *canopy-max-width* 60)
(define *canopy-search-height* 3)
;; the search box only takes rows while a query is active; the tree owns the
;; full panel at rest
(define (canopy-search-height-now)
  (if (or *canopy-typing?* (canopy-searching?)) *canopy-search-height* 0))
(define *canopy-auto-reveal* #t) ; follow the focused buffer in the tree
(define *canopy-use-trash* 'auto) ; 'auto tries trash/trash-put/gio before rm; 'never deletes directly
(define *canopy-last-active-path* #f)
(define *canopy-side* 'left) ; left or right set with canopy-configure!
(define *canopy-linear-nav?* #t) ; linear vim-style movement through the whole visible tree (set #f for sibling-wrap)
(define *canopy-show-separator?* #t)
(define *canopy-bg-focused* #f)
(define *canopy-bg-unfocused* #f)
(define *canopy-search-color-focused* #f)
(define *canopy-search-color-unfocused* #f)
(define *canopy-search-default-focused* "#ffa500")
(define *canopy-search-default-unfocused* "#ffffff")
(define *canopy-search-follow-focus?* #t)

(define *canopy-ignore-set*
  (hashset ".git" "target" ".direnv" "node_modules" "__pycache__" ".hg"))

;; dotfiles and git-ignored entries are hidden by default
(define *canopy-show-hidden* #f)
(define *canopy-show-git-ignored* #f)
(define *canopy-git-ignored-set* (hashset))

(define (canopy-dotfile? name)
  (and (> (string-length name) 0) (char=? (string-ref name 0) #\.)))

(define (canopy-git-repo? dir)
  (let ([proc (~> (command "git" (list "-C" dir "rev-parse" "--is-inside-work-tree"))
                  with-stdout-piped
                  with-stderr-piped
                  spawn-process)])
    (and (Ok? proc)
         (string=? (trim (read-port-to-string (child-stdout (Ok->value proc)))) "true"))))

(define *canopy-git-status-map* (hash))

;; classifies a porcelain code as untracked, added, deleted, renamed, or modified
(define (canopy-git-status-symbol code)
  (define x (string-ref code 0))
  (define y (string-ref code 1))
  (cond
    [(and (char=? x #\?) (char=? y #\?)) 'untracked]
    [(or (char=? x #\A) (char=? y #\A)) 'added]
    [(or (char=? x #\D) (char=? y #\D)) 'deleted]
    [(or (char=? x #\R) (char=? y #\R)) 'renamed]
    [(or (char=? x #\M) (char=? y #\M)) 'modified]
    [else #f]))

(define (canopy-status-path rest)
  (define parts (split-many rest " -> "))
  (trim-end-matches (if (> (length parts) 1) (list-ref parts (- (length parts) 1)) rest)
                     (path-separator)))

(define (canopy-parse-git-status-lines lines)
  (let loop ([ls lines] [ign (hashset)] [statuses (hash)])
    (if (null? ls)
        (cons ign statuses)
        (let ([line (car ls)])
          (if (< (string-length line) 3)
              (loop (cdr ls) ign statuses)
              (let* ([code (substring line 0 2)]
                     [path (canopy-status-path (trim (substring line 3 (string-length line))))])
                (if (string=? code "!!")
                    (loop (cdr ls) (hashset-insert ign path) statuses)
                    (let ([sym (canopy-git-status-symbol code)])
                      (loop (cdr ls) ign (if sym (hash-insert statuses path sym) statuses))))))))))

;; porcelain paths are relative to the REPO root, which can differ from the
;; tree root after a root dive; matching must strip the repo-root prefix
(define *canopy-git-toplevel* #f)

(define (canopy-scan-git-toplevel! root)
  (set! *canopy-git-toplevel*
        (with-handler
          (lambda (_) #f)
          (let ([proc (~> (command "git" (list "-C" root "rev-parse" "--show-toplevel"))
                          with-stdout-piped
                          with-stderr-piped
                          spawn-process)])
            (if (Ok? proc)
                (let ([out (trim (read-port-to-string (child-stdout (Ok->value proc))))])
                  (if (> (string-length out) 0) out #f))
                #f)))))

;; recomputes which workspace-relative paths git considers ignored
(define (canopy-scan-git-ignored! root)
  (canopy-scan-git-toplevel! root)
  (define parsed
    (with-handler
      (lambda (_) (cons (hashset) (hash)))
      (if (not (canopy-git-repo? root))
          (cons (hashset) (hash))
          (let ([proc (~> (command "git" (list "-C" root "status" "--porcelain" "--ignored=matching"))
                          with-stdout-piped
                          with-stderr-piped
                          spawn-process)])
            (if (Ok? proc)
                (let* ([output (read-port-to-string (child-stdout (Ok->value proc)))]
                       [lines (filter (lambda (l) (> (string-length l) 0)) (split-many output "\n"))])
                  (canopy-parse-git-status-lines lines))
                (cons (hashset) (hash)))))))
  (set! *canopy-git-ignored-set* (car parsed))
  (set! *canopy-git-status-map* (cdr parsed)))

(define *canopy-active* #f)
(define *canopy-focused* #f)
(define *canopy-tree* '())
(define *canopy-cursor* 0)
(define *canopy-window-start* 0)
(define *canopy-visible-height* 30)
(define *canopy-directories* (hash))
(define *canopy-query* "")
(define *canopy-all-files* '())
(define *canopy-search-results* '())
(define *canopy-typing?* #f)
(define *canopy-pending-g* #f) ; first g of a gg sequence seen
(define *canopy-pending-space* #f) ; mini-leader armed (space f / space e / space space)

(define *canopy-default-keybinds*
  (hash 'down "j"
        'up "k"
        'enter "l" ; snacks: enter dir or open file; mini: cascade
        'back "h" ; snacks: leave folder; mini: parent column
        'search "/"
        'create "n"
        'rename "r"
        'delete "d"
        'refresh "R"
        'toggle-hidden "."
        'toggle-git-ignored "i"
        'bottom "G"
        'move "m"
        'reveal "f"
        'yank "y"
        'paste "p"
        'copy-path "Y"
        'root-dive ">"
        'root-up "<"
        'preview "P"
        'wider "+"
        'narrower "-"
        'quit "q")) ; space is a mini-leader handled in the event loop; ? opens help

(define *canopy-keybinds* *canopy-default-keybinds*)

;; looks up which action (if any) a keypress is bound to
(define (canopy-action-for-char ch)
  (define s (string ch))
  (let loop ([ks (hash-keys->list *canopy-keybinds*)])
    (cond
      [(null? ks) #f]
      [(equal? (hash-try-get *canopy-keybinds* (car ks)) s) (car ks)]
      [else (loop (cdr ks))])))

(provide canopy-open)
(provide canopy-start!)
(provide canopy-focus)
(provide canopy-toggle)
(provide canopy-close)
(provide canopy-configure!)
(provide canopy-set-style!)
(provide canopy-set-keybinds!)
(provide canopy-set-linear-nav!)
(provide canopy-set-sidebar-bg!)
(provide canopy-set-search-color!)
(provide canopy-snacks-active?)
(provide canopy-snacks-side)
(provide canopy-snacks-width)

;;@doc
;; true while the snacks sidebar is open, so other plugins can keep off it
(define (canopy-snacks-active?)
  (and *canopy-active* (equal? *canopy-style* 'snacks)))

;;@doc
;; Side the snacks sidebar sits on: 'left or 'right
(define (canopy-snacks-side)
  *canopy-side*)

;;@doc
;; Width in columns of the snacks sidebar, 0 while it is closed
(define (canopy-snacks-width)
  (if (and *canopy-active* (equal? *canopy-style* 'snacks)) *canopy-width* 0))

;;@doc
;; Override any subset of canopy's keybindings from init.scm
;; (canopy-set-keybinds! (hash 'rename "R" 'refresh "r"))
(define (canopy-set-keybinds! overrides)
  (set! *canopy-keybinds*
        (let loop ([ks (hash-keys->list overrides)] [acc *canopy-keybinds*])
          (if (null? ks)
              acc
              (loop (cdr ks) (hash-insert acc (car ks) (hash-try-get overrides (car ks))))))))

;;@doc
;; Set which side the file tree renders, hidden entries, and whether a
;; vertical separator line is drawn between the tree and the text buffer
(define (canopy-configure! side
                            #:ignore [ignore (list )]
                            #:separator? [separator? #t]
                            #:linear-nav [linear-nav #t]
                            #:auto-reveal [auto-reveal #t]
                            #:use-trash [use-trash 'auto])
  (set! *canopy-side* side)
  (set! *canopy-ignore-set* (apply hashset ignore))
  (set! *canopy-show-separator?* separator?)
  (set! *canopy-linear-nav?* linear-nav)
  (set! *canopy-auto-reveal* auto-reveal)
  (set! *canopy-use-trash* use-trash))

(define (canopy-set-linear-nav! on?)
  (set! *canopy-linear-nav?* on?))

(define *canopy-style* 'snacks)

;;@doc
;; Pick which explorer UI canopy-open uses: 'snacks or 'mini
(define (canopy-set-style! style)
  (set! *canopy-style* style))

;; #rrggbb string to a Color, or #f on anything unparseable
(define (canopy-hex->color hex)
  (and (string? hex) (with-handler (lambda (_) #f) (glyph-hex->color hex))))

;;@doc
;; Give the snacks sidebar its own background per focus state
(define (canopy-set-sidebar-bg! #:focused [focused #f] #:unfocused [unfocused #f])
  (set! *canopy-bg-focused* (canopy-hex->color focused))
  (set! *canopy-bg-unfocused* (canopy-hex->color unfocused)))

;; the sidebar background for the current focus state, or #f for the theme default
(define (canopy-panel-bg-color)
  (if *canopy-focused* *canopy-bg-focused* *canopy-bg-unfocused*))

;;@doc
;; Color the snacks search box per focus mode
(define (canopy-set-search-color! #:focused [focused #f]
                                   #:unfocused [unfocused #f]
                                   #:always [always #f]
                                   #:follow-focus? [follow-focus? #t])
  (define both (canopy-hex->color always))
  (set! *canopy-search-color-focused* (or both (canopy-hex->color focused)))
  (set! *canopy-search-color-unfocused* (or both (canopy-hex->color unfocused)))
  (set! *canopy-search-follow-focus?* (if both #f follow-focus?)))

;; search box outline color for the current focus state
(define (canopy-search-color)
  (if (or (not *canopy-search-follow-focus?*) *canopy-focused*)
      (or *canopy-search-color-focused* (canopy-hex->color *canopy-search-default-focused*))
      (or *canopy-search-color-unfocused* (canopy-hex->color *canopy-search-default-unfocused*))))

;; keep the panel off the rows moka reserves at the bottom
(define *canopy-reserved-bottom-fn* 'unresolved)

(define (canopy-resolve-reserved!)
  (when (equal? *canopy-reserved-bottom-fn* 'unresolved)
    (set! *canopy-reserved-bottom-fn* (with-handler (lambda (_) #f) (eval 'moka-reserved-bottom)))))

(define (canopy-reserved-bottom)
  (canopy-resolve-reserved!)
  (if *canopy-reserved-bottom-fn* (with-handler (lambda (_) 0) (*canopy-reserved-bottom-fn*)) 0))

;; tell moka and scopeline where the snacks sidebar is, so their bars stop at the buffer
;; eval-string so a missing plugin is a no-op instead of a load error
(define (canopy-publish-clip! side w)
  (define side-expr (if side (string-append "'" (symbol->string side)) "#f"))
  (define w-expr (number->string (if (number? w) w 0)))
  (define args (string-append " " side-expr " " w-expr ")"))
  (with-handler (lambda (_) #f)
    (eval-string (string-append "(moka-set-canopy-clip!" args)))
  (with-handler (lambda (_) #f)
    (eval-string (string-append "(scopeline-set-canopy-clip!" args))))

(define (canopy-clear-clip!)
  (canopy-publish-clip! #f 0)
  (if (equal? *canopy-side* 'right)
      (set-editor-clip-right! 0)
      (set-editor-clip-left! 0)))

(define (canopy-take lst n)
  (if (or (null? lst) (<= n 0)) '() (cons (car lst) (canopy-take (cdr lst) (- n 1)))))

(define (canopy-drop lst n)
  (if (or (null? lst) (<= n 0)) lst (canopy-drop (cdr lst) (- n 1))))

(define (canopy-truncate s max-w)
  (if (<= (string-length s) max-w)
      s
      (string-append (substring s 0 (max 0 (- max-w 1))) "…")))

(define (canopy-repeat-str s n)
  (if (<= n 0) "" (string-append s (canopy-repeat-str s (- n 1)))))

(struct CanopyHelpState ())
(define *canopy-help-open?* #f)
(define *canopy-help-style* 'snacks)
(define *canopy-help-dispatch* #f)

;; the bound key for an action with fallback to ?
(define (canopy-help-key action)
  (define k (hash-try-get *canopy-keybinds* action))
  (cond
    [(equal? k " ") "space"]
    [(and (string? k) (not (equal? k ""))) k]
    [else "?"]))

;; snacks keybinds
(define (canopy-snacks-help-rows)
  (list
    (list (string-append (canopy-help-key 'down) " / " (canopy-help-key 'up) " / ↑ / ↓") "Move through the tree")
    (list "gg / G" "Top / bottom")
    (list "C-d / C-u" "Half page down / up")
    (list (string-append (canopy-help-key 'enter) " / →") "Expand dir or open file")
    (list (string-append (canopy-help-key 'back) " / ←") "Collapse dir, else parent")
    (list "Enter / Tab" "Open file / toggle dir")
    (list "C-s / C-v" "Open in split")
    (list "> / <" "Dive into dir as root / climb out")
    (list (canopy-help-key 'preview) "Toggle preview popup")
   (list (canopy-help-key 'search) "Fuzzy search")
   (list "Space f / Space e" "File picker / toggle panel")
   (list (canopy-help-key 'reveal) "Reveal current file")
   (list (canopy-help-key 'create) "Create file or dir")
   (list (canopy-help-key 'rename) "Rename entry")
   (list (canopy-help-key 'move) "Move entry")
   (list (string-append (canopy-help-key 'yank) " / " (canopy-help-key 'paste)) "Yank / paste copy")
   (list (canopy-help-key 'copy-path) "Copy path to clipboard")
   (list (canopy-help-key 'delete) "Delete entry (trash if available)")
   (list (canopy-help-key 'refresh) "Refresh tree")
   (list (canopy-help-key 'toggle-hidden) "Toggle dotfiles")
   (list (canopy-help-key 'toggle-git-ignored) "Toggle git-ignored")
   (list (string-append (canopy-help-key 'wider) " / " (canopy-help-key 'narrower)) "Widen or narrow panel")
   (list "Esc / C-l" "Focus editor")
   (list (canopy-help-key 'quit) "Close panel")))

;; mini keybinds
(define (canopy-mini-help-rows)
  (list
   (list (string-append (canopy-help-key 'down) " / " (canopy-help-key 'up) " / ↑ / ↓") "Move")
   (list (string-append (canopy-help-key 'enter) " / → / Enter") "Open file or enter dir")
   (list (string-append (canopy-help-key 'back) " / ←") "Parent column")
   (list (canopy-help-key 'search) "Fuzzy search")
   (list (canopy-help-key 'create) "Create file or dir")
   (list (canopy-help-key 'rename) "Rename entry")
   (list (canopy-help-key 'delete) "Delete entry")
   (list (canopy-help-key 'refresh) "Refresh column")
   (list (canopy-help-key 'toggle-hidden) "Toggle dotfiles")
   (list (canopy-help-key 'toggle-git-ignored) "Toggle git-ignored")
   (list (string-append (canopy-help-key 'wider) " / " (canopy-help-key 'narrower)) "Widen or narrow")
   (list (string-append "Esc / " (canopy-help-key 'quit)) "Close")))

;; helix style box tucked into the bottom right corner
(define (canopy-help-metrics rect rows)
  (define key-w (apply max (cons 1 (map (lambda (r) (string-length (car r))) rows))))
  (define desc-w (apply max (cons 1 (map (lambda (r) (string-length (cadr r))) rows))))
  (define content-w (+ key-w 2 desc-w))
  (define w (min (max 0 (- (area-width rect) 2)) (+ content-w 4)))
  ;; two borders around one row per binding
  (define h (min (max 0 (- (area-height rect) 2)) (+ (length rows) 2)))
  ;; placed above the statusline plus any reserved line, e.g. for moka
  (define bottom (+ (canopy-reserved-bottom) 2))
  (define x (max 0 (- (area-width rect) w)))
  (define y (max 0 (- (area-height rect) h bottom)))
  (list x y w h key-w))

(define (canopy-help-render state rect frame)
  (define rows (if (equal? *canopy-help-style* 'mini) (canopy-mini-help-rows) (canopy-snacks-help-rows)))

  ;; popup kit: ui.popup backdrop, undimmed border, bold title in the edge
  (define bg-style (theme-scope-ref "ui.popup"))
  (define popup-bg (style->bg bg-style))
  (define (on-popup s) (if popup-bg (style-bg s popup-bg) s))
  (define text-style (on-popup (theme-scope-ref "ui.text")))
  (define key-style (style-with-bold (on-popup (theme-scope-ref "ui.text.info"))))
  (define border-style text-style)

  (define m (canopy-help-metrics rect rows))
  (define x (list-ref m 0))
  (define y (list-ref m 1))
  (define w (list-ref m 2))
  (define h (list-ref m 3))
  (define key-w (list-ref m 4))

  (define box (area x y w h))
  (define inner-x (+ x 1))

  (buffer/clear-with frame box bg-style)
  (block/render frame box (make-block bg-style border-style "all" "rounded"))
  (when (> w 10)
    (frame-set-string! frame (+ x 2) y " help " (style-with-bold border-style)))

  (let loop ([rs rows] [row 0])
    (when (and (pair? rs) (< row (- h 2)))
      (define r (car rs))
      (define ry (+ y 1 row))
      (define dx (+ inner-x 1 key-w 2))
      (define avail (max 0 (- (+ x w) 1 dx)))
      (frame-set-string! frame (+ inner-x 1) ry (car r) key-style)
      (frame-set-string! frame dx ry (canopy-truncate (cadr r) avail) text-style)
      (loop (cdr rs) (+ row 1)))))

;; pressing a listed key runs that action and closes; esc or any unbound key
;; closes without running anything
(define (canopy-help-handle-event state event)
  (define ch (key-event-char event))
  (cond
    [(mouse-event? event) event-result/consume]
    [(key-event-escape? event) (set! *canopy-help-open?* #f) event-result/close]
    [(char? ch)
     (define action (canopy-action-for-char ch))
     (define dispatch *canopy-help-dispatch*)
     (set! *canopy-help-open?* #f)
     (when (and action dispatch (not (equal? action 'menu)))
       ;; deferred so the menu is gone before the action pushes a modal of its own
       (enqueue-thread-local-callback (lambda () (dispatch action))))
     event-result/close]
    [else (set! *canopy-help-open?* #f) event-result/close]))

;; pops the popup from outside its own handler, e.g. when the explorer closes
(define (canopy-help-dismiss!)
  (when *canopy-help-open?*
    (set! *canopy-help-open?* #f)
    (pop-last-component-by-name! "canopy-help")))

;; space opens the which-key menu
(define (canopy-whichkey-open! style dispatch)
  (unless *canopy-help-open?*
    (set! *canopy-help-style* style)
    (set! *canopy-help-dispatch* dispatch)
    (set! *canopy-help-open?* #t)
    (push-component!
     (new-component! "canopy-help"
                     (CanopyHelpState)
                     canopy-help-render
                     (hash "handle_event" canopy-help-handle-event)))))

;; strips the workspace prefix so prompts show a short path instead of the full one
(define (canopy-relpath path)
  (define prefix (string-append (canopy-root) (path-separator)))
  (if (and (>= (string-length path) (string-length prefix))
           (equal? (substring path 0 (string-length prefix)) prefix))
      (substring path (string-length prefix) (string-length path))
      path))

(define (canopy-git-relpath path)
  (define top (or *canopy-git-toplevel* (canopy-root)))
  (define prefix (string-append top (path-separator)))
  (if (and (>= (string-length path) (string-length prefix))
           (equal? (substring path 0 (string-length prefix)) prefix))
      (substring path (string-length prefix) (string-length path))
      path))

(define (canopy-git-ignored? path)
  (hashset-contains? *canopy-git-ignored-set* (canopy-git-relpath path)))

(define (canopy-git-status path)
  (hash-try-get *canopy-git-status-map* (canopy-git-relpath path)))

;; git state renders as a themed dot plus a matching filename tint
(define (canopy-git-scope status)
  (cond
    [(equal? status 'deleted) (theme-scope-ref "diff.minus")]
    [(or (equal? status 'untracked) (equal? status 'added)) (theme-scope-ref "diff.plus")]
    [else (theme-scope-ref "diff.delta")]))

;; a directory is marked when any changed file lives underneath it
(define (canopy-dir-has-changes? path)
  (define rel (string-append (canopy-git-relpath path) "/"))
  (let loop ([ks (hash-keys->list *canopy-git-status-map*)])
    (cond
      [(null? ks) #f]
      [(starts-with? (car ks) rel) #t]
      [else (loop (cdr ks))])))

(define (canopy-searching?) (not (equal? *canopy-query* "")))

;; dirs before files, alphabetic order
(define (canopy-sort-entries lst)
  (define dirs (sort (filter is-dir? lst) string<?))
  (define files (sort (filter (lambda (p) (not (is-dir? p))) lst) string<?))
  (append dirs files))

;; path -> literal link target for every symlink visible in the tree; rebuilt
;; on each tree build so replaced links can't go stale, targets cached across
;; builds to avoid respawning readlink
(define *canopy-symlink-map* (hash))

(define (canopy-readlink path)
  (with-handler
    (lambda (_) #f)
    (let ([proc (~> (command "readlink" (list path))
                    with-stdout-piped
                    with-stderr-piped
                    spawn-process)])
      (and (Ok? proc)
           (let ([out (trim (read-port-to-string (child-stdout (Ok->value proc))))])
             (and (> (string-length out) 0) out))))))

;; list a directory through the entry iterator so symlinks are known from the
;; dirent itself (file-metadata follows links and can't see them); returns
;; (path . symlink?) pairs
(define (canopy-list-dir-entries dir)
  (with-handler
    (lambda (_) '())
    (let ([it (read-dir-iter dir)])
      (let loop ([acc '()])
        (let ([e (read-dir-iter-next! it)])
          (if e
              (loop (cons (cons (read-dir-entry-path e) (read-dir-entry-is-symlink? e)) acc))
              (reverse acc)))))))

;; slim Nerd Font angle chevrons, built from codepoints so no editor or
;; copy-paste step can silently mangle the private-use glyphs
(define *canopy-chevron-collapsed* (string (integer->char #xf105) #\space)) ; nf-fa-angle_right
(define *canopy-chevron-expanded*  (string (integer->char #xf107) #\space)) ; nf-fa-angle_down

(define (canopy-dir-marker path)
  (if (hash-contains? *canopy-directories* path)
      (if (hash-try-get *canopy-directories* path)
          *canopy-chevron-collapsed*
          *canopy-chevron-expanded*)
      *canopy-chevron-collapsed*))

(define (canopy-build-tree!)
  (define result '())
  (define new-links (hash))
  (define (children-of path)
    (map (lambda (pr)
           (define p (car pr))
           (when (cdr pr)
             (set! new-links
                   (hash-insert new-links p
                                (or (hash-try-get *canopy-symlink-map* p)
                                    (canopy-readlink p)
                                    "?"))))
           p)
         (canopy-list-dir-entries path)))
  (define (walk path depth)
    (define name (file-name path))
    (unless (or (hashset-contains? *canopy-ignore-set* name)
                (and (not *canopy-show-hidden*) (canopy-dotfile? name))
                (and (not *canopy-show-git-ignored*) (canopy-git-ignored? path)))
      ;; indent guides: one faint spine per ancestor level (rendered dim)
      (define indent (canopy-repeat-str "│ " depth))
      (define marker (if (is-dir? path) (canopy-dir-marker path) "  "))
      (set! result (cons (list path indent marker name) result))
      (when (is-dir? path)
        (unless (hash-contains? *canopy-directories* path)
          (set! *canopy-directories* (hash-insert *canopy-directories* path (> depth 0))))
        (unless (hash-try-get *canopy-directories* path)
          (for-each (lambda (child) (walk child (+ depth 1)))
                    (canopy-sort-entries (children-of path)))))))
  (walk (canopy-root) 0)
  (set! *canopy-symlink-map* new-links)
  (set! *canopy-tree* (reverse result)))

(define (canopy-parent-path path)
  (trim-end-matches path (string-append (path-separator) (file-name path))))

(define (canopy-half-floor n)
  (let loop ([n n] [h 0])
    (if (< n 2) h (loop (- n 2) (+ h 1)))))

;; expands every dir between the workspace root and path
(define (canopy-open-ancestors-for-file! path)
  (define ws (canopy-root))
  (define ws-prefix (string-append ws (path-separator)))
  (when (and (string? path)
             (>= (string-length path) (string-length ws-prefix))
             (equal? (substring path 0 (string-length ws-prefix)) ws-prefix))
    (define (open-up! p)
      (define parent (canopy-parent-path p))
      (set! *canopy-directories* (hash-insert *canopy-directories* parent #f))
      (unless (equal? parent ws)
        (open-up! parent)))
    (open-up! path)))

;; moves the cursor to the file path
(define (canopy-seek-file! path)
  (when (string? path)
    (define idx
      (let loop ([items *canopy-tree*] [i 0])
        (cond [(null? items) #f]
              [(equal? (car (car items)) path) i]
              [else (loop (cdr items) (+ i 1))])))
    (when idx
      (set! *canopy-cursor* idx)
      (set! *canopy-window-start*
            (max 0 (- idx (canopy-half-floor *canopy-visible-height*)))))))

(define (canopy-reveal-current-file!)
  (define path (editor-document->path (editor->doc-id (editor-focus))))
  (canopy-open-ancestors-for-file! path)
  (canopy-build-tree!)
  (unless (canopy-searching?)
    (canopy-seek-file! path))
  ;; workspace row is only a parent, start on its first child so j/k work immediately
  (let ([entry (canopy-current-entry)])
    (when (and entry (equal? (car entry) (canopy-root)))
      (canopy-enter-dir! (car entry)))))

;; flat recursive file list for search
;; searches files independent of the fold state
(define (canopy-scan-files!)
  (define root (canopy-root))
  (define root-prefix (string-append root (path-separator)))
  (define acc '())
  (define (walk dir)
    (for-each
     (lambda (p)
       (define name (file-name p))
       ;; search respects the same visibility toggles as the tree
       (unless (or (hashset-contains? *canopy-ignore-set* name)
                   (and (not *canopy-show-hidden*) (starts-with? name "."))
                   (and (not *canopy-show-git-ignored*) (canopy-git-ignored? p)))
         (if (is-dir? p)
             (walk p)
             (set! acc (cons p acc)))))
     (with-handler (lambda (_) '()) (read-dir dir))))
  (walk root)
  (set! *canopy-all-files*
        (sort (map (lambda (p) (substring p (string-length root-prefix) (string-length p))) acc)
              string<?)))

(define (canopy-active-count)
  (if (canopy-searching?) (length *canopy-search-results*) (length *canopy-tree*)))

(define (canopy-index-of lst x)
  (let loop ([xs lst] [i 0])
    (cond
      [(null? xs) #f]
      [(equal? (car xs) x) i]
      [else (loop (cdr xs) (+ i 1))])))

(define (canopy-wrap i n)
  (cond
    [(< i 0) (- n 1)]
    [(>= i n) 0]
    [else i]))

(define (canopy-ensure-cursor-visible!)
  (define last-vis (+ *canopy-window-start* (- *canopy-visible-height* 1)))
  (when (> *canopy-cursor* last-vis)
    (set! *canopy-window-start* (- *canopy-cursor* (- *canopy-visible-height* 1))))
  (when (< *canopy-cursor* *canopy-window-start*)
    (set! *canopy-window-start* *canopy-cursor*)))

;; indices of entries that share the current entry's parent
(define (canopy-sibling-indices)
  (define entry (canopy-current-entry))
  (if (not entry)
      '()
      (let ([parent (canopy-parent-path (car entry))])
        (let loop ([items *canopy-tree*] [i 0] [acc '()])
          (cond
            [(null? items) (reverse acc)]
            [(equal? (canopy-parent-path (car (car items))) parent)
             (loop (cdr items) (+ i 1) (cons i acc))]
            [else (loop (cdr items) (+ i 1) acc)])))))

(define (canopy-cursor-sibling! delta)
  (define idxs (canopy-sibling-indices))
  (define n (length idxs))
  (define pos (canopy-index-of idxs *canopy-cursor*))
  (when (and (> n 0) pos)
    (set! *canopy-cursor* (list-ref idxs (canopy-wrap (+ pos delta) n)))
    (canopy-ensure-cursor-visible!)))

;; moves through the flat visible tree, clamped at the ends
(define (canopy-cursor-linear! delta)
  (define n (length *canopy-tree*))
  (when (> n 0)
    (set! *canopy-cursor* (max 0 (min (+ *canopy-cursor* delta) (- n 1))))
    (canopy-ensure-cursor-visible!)))

(define (canopy-cursor-down!)
  (if (canopy-searching?)
      (let ([n (canopy-active-count)])
        (when (> n 0)
          (set! *canopy-cursor* (canopy-wrap (+ *canopy-cursor* 1) n))
          (canopy-ensure-cursor-visible!)))
      (if *canopy-linear-nav?*
          (canopy-cursor-linear! 1)
          (canopy-cursor-sibling! 1))))

(define (canopy-cursor-up!)
  (if (canopy-searching?)
      (let ([n (canopy-active-count)])
        (when (> n 0)
          (set! *canopy-cursor* (canopy-wrap (- *canopy-cursor* 1) n))
          (canopy-ensure-cursor-visible!)))
      (if *canopy-linear-nav?*
          (canopy-cursor-linear! -1)
          (canopy-cursor-sibling! -1))))

(define (canopy-current-entry)
  (if (canopy-searching?)
      (and (not (null? *canopy-search-results*))
           (let ([rel (list-ref *canopy-search-results* *canopy-cursor*)])
             (cons (string-append (canopy-root) (path-separator) rel) rel)))
      (and (not (null? *canopy-tree*))
           (list-ref *canopy-tree* *canopy-cursor*))))

(define (canopy-refresh-search!)
  (set! *canopy-search-results*
        (if (canopy-searching?) (fuzzy-match *canopy-query* *canopy-all-files*) '())))

(define (canopy-type! ch)
  (set! *canopy-query* (string-append *canopy-query* (string ch)))
  (canopy-refresh-search!)
  (set! *canopy-cursor* 0)
  (set! *canopy-window-start* 0))

(define (canopy-backspace!)
  (define len (string-length *canopy-query*))
  (when (> len 0)
    (set! *canopy-query* (substring *canopy-query* 0 (- len 1))))
  (canopy-refresh-search!)
  (set! *canopy-cursor* 0)
  (set! *canopy-window-start* 0))

(define *canopy-presearch-cursor* 0)
(define *canopy-presearch-window* 0)

;; / starts a new query, so letters stay free for single-key commands
(define (canopy-enter-search!)
  ;; remember where browsing left off, so escape can put the tree back
  (unless (canopy-searching?)
    (set! *canopy-presearch-cursor* *canopy-cursor*)
    (set! *canopy-presearch-window* *canopy-window-start*))
  (set! *canopy-typing?* #t)
  (set! *canopy-query* "")
  (canopy-refresh-search!)
  (set! *canopy-cursor* 0)
  (set! *canopy-window-start* 0))

;; drops the query and restores the tree to its pre-search position
(define (canopy-search-restore!)
  (set! *canopy-typing?* #f)
  (set! *canopy-query* "")
  (canopy-refresh-search!)
  (set! *canopy-cursor* (min *canopy-presearch-cursor* (max 0 (- (length *canopy-tree*) 1))))
  (set! *canopy-window-start* *canopy-presearch-window*))

(define (canopy-clear-search!)
  (set! *canopy-query* "")
  (canopy-refresh-search!)
  (set! *canopy-cursor* 0)
  (set! *canopy-window-start* 0))

;; refreshes the view after an action like deletion
(define (canopy-refresh-all!)
  (define old *canopy-cursor*)
  (canopy-scan-git-ignored! (canopy-root)) ; badges refresh with the tree
  (set! *canopy-symlink-map* (hash))       ; re-read link targets too
  (canopy-build-tree!)
  (canopy-scan-files!)
  (canopy-refresh-search!)
  (set! *canopy-cursor* (min old (max 0 (- (canopy-active-count) 1)))))

(define *canopy-refresh-mini-fn* #f)

;; refreshes whichever style is active
(define (canopy-refresh-current-style!)
  (if (and (equal? *canopy-style* 'mini) *canopy-refresh-mini-fn*)
      (*canopy-refresh-mini-fn*)
      (canopy-refresh-all!)))

(define (canopy-toggle-hidden!)
  (set! *canopy-show-hidden* (not *canopy-show-hidden*))
  (canopy-info (if *canopy-show-hidden* "canopy: showing dotfiles" "canopy: hiding dotfiles"))
  (canopy-refresh-current-style!))

(define (canopy-toggle-git-ignored!)
  (set! *canopy-show-git-ignored* (not *canopy-show-git-ignored*))
  (canopy-info (if *canopy-show-git-ignored* "canopy: showing git-ignored" "canopy: hiding git-ignored"))
  (canopy-refresh-current-style!))

(define (canopy-toggle-dir! path)
  (set! *canopy-directories*
        (hash-insert *canopy-directories* path (not (hash-try-get *canopy-directories* path))))
  (define old *canopy-cursor*)
  (canopy-build-tree!)
  (set! *canopy-cursor* (min old (max 0 (- (length *canopy-tree*) 1))))
  (canopy-save-state!))

;; helix renders binary files as raw bytes in the buffer; refuse the well-known ones
(define *canopy-binary-extensions*
  (hashset "png" "jpg" "jpeg" "gif" "bmp" "webp" "ico" "icns" "tif" "tiff" "avif" "heic"
           "pdf" "zip" "tar" "gz" "tgz" "xz" "zst" "bz2" "7z" "rar" "jar"
           "exe" "dll" "so" "dylib" "o" "a" "class" "wasm" "pyc"
           "sqlite" "sqlite3" "db"
           "mp3" "mp4" "m4a" "avi" "mkv" "mov" "wav" "flac" "ogg" "webm"
           "ttf" "otf" "woff" "woff2" "eot"))

(define (canopy-binary-path? path)
  (define parts (split-many (file-name path) "."))
  (and (> (length parts) 1)
       (hashset-contains? *canopy-binary-extensions*
                          (string-foldcase (list-ref parts (- (length parts) 1))))))

;; opens the file under the cursor; split is 'none, 'horizontal, or 'vertical
(define (canopy-open-current! split)
  (define entry (canopy-current-entry))
  (cond
    [(and entry (is-file? (car entry)))
     (define path (car entry))
     (cond
       [(canopy-binary-path? path)
        (canopy-info (string-append "canopy: " (file-name path) " is a binary file, not opening"))
        event-result/consume]
       [else
        ;; opening from a search commits it: clear the query and reveal the
        ;; opened file in the restored tree
        (define from-search? (canopy-searching?))
        ;; hand focus to the buffer about to open
        (set! *canopy-focused* #f)
        (enqueue-thread-local-callback
         (lambda ()
           (cond
             [(equal? split 'horizontal) (helix.hsplit path)]
             [(equal? split 'vertical) (helix.vsplit path)]
             [else (helix.open path)])
           (when from-search?
             (canopy-search-restore!)
             (canopy-reveal-current-file!))))
        event-result/close])]
    [else event-result/consume]))

(define (canopy-activate!)
  (define entry (canopy-current-entry))
  (cond
    [(not entry) event-result/consume]
    [(is-file? (car entry)) (canopy-open-current! 'none)]
    [(is-dir? (car entry))
     (canopy-toggle-dir! (car entry))
     event-result/consume]))

(define (canopy-dir-expanded? path)
  (and (is-dir? path)
       (hash-contains? *canopy-directories* path)
       (not (hash-try-get *canopy-directories* path))))

(define (canopy-path-in-workspace? path)
  (define ws (canopy-root))
  (or (equal? path ws)
      (starts-with? path (string-append ws (path-separator)))))

(define (canopy-first-child-index path)
  (let loop ([items *canopy-tree*] [i 0])
    (cond
      [(null? items) #f]
      [(equal? (canopy-parent-path (car (car items))) path) i]
      [else (loop (cdr items) (+ i 1))])))

;; expand if needed and move onto the first child
(define (canopy-enter-dir! path)
  (unless (canopy-dir-expanded? path)
    (canopy-toggle-dir! path))
  (define idx (canopy-first-child-index path))
  (when idx
    (set! *canopy-cursor* idx)
    (canopy-ensure-cursor-visible!)))

(define (canopy-enter-or-open!)
  (define entry (canopy-current-entry))
  (cond
    [(not entry) event-result/consume]
    [(is-file? (car entry)) (canopy-activate!)]
    [(is-dir? (car entry))
     (canopy-enter-dir! (car entry))
     event-result/consume]
    [else event-result/consume]))

;; vim-style h: collapse the expanded dir under the cursor, else jump to parent
(define (canopy-goto-parent!)
  (define entry (canopy-current-entry))
  (when (and entry (not (canopy-searching?)))
    (define path (car entry))
    (define ws (canopy-root))
    (cond
      [(and (is-dir? path) (canopy-dir-expanded? path) (not (equal? path ws)))
       (canopy-toggle-dir! path)]
      [(equal? path ws) void]
      [else
       (define parent (canopy-parent-path path))
       (when (and (string? parent) (canopy-path-in-workspace? parent))
         (canopy-seek-file! parent))])))

(define (canopy-unfocus!)
  (canopy-reset-mouse!)
  (set! *canopy-focused* #f))

;; leaves the tree focused but pops it off the stack, so the editor gets input again
;; this has to be reachable from inside canopy-handle-event-fg directly: while focused,
;; the fg component owns every keypress, so a global leader keymap like space+e never
;; reaches Helix's keymap layer to re-invoke canopy-open
(define (canopy-switch-to-editor!)
  (pop-last-component-by-name! "canopy-fg")
  (canopy-unfocus!))

(define (canopy-close!)
  (canopy-save-state!)
  (canopy-reset-mouse!)
  (canopy-help-dismiss!)
  (set! *canopy-active* #f)
  (set! *canopy-focused* #f)
  (canopy-clear-clip!)
  (pop-last-component-by-name! "canopy-fg")
  (pop-last-component-by-name! "canopy-bg")
  (enqueue-thread-local-callback
   (lambda ()
     (canopy-clear-clip!)
     (helix.redraw))))

(define (canopy-wider!)
  (set! *canopy-width* (min *canopy-max-width* (+ *canopy-width* 2)))
  (helix.redraw))

(define (canopy-narrower!)
  (set! *canopy-width* (max *canopy-min-width* (- *canopy-width* 2)))
  (helix.redraw))

(define *canopy-modal-open?* #f)
(define *canopy-modal-mode* 'input)
(define *canopy-modal-label* "")
(define *canopy-modal-title* "")
(define *canopy-modal-buffer* "")
(define *canopy-modal-callback* #f)

(struct CanopyModalState ())

(define (canopy-modal-width rect)
  (define content-len (+ (string-length *canopy-modal-label*) (string-length *canopy-modal-buffer*)))
  (min (- (area-width rect) 4) (max 40 (+ content-len 4))))

(define (canopy-modal-origin rect)
  (define w (canopy-modal-width rect))
  (define x (quotient (- (area-width rect) w) 2))
  (define y (quotient (- (area-height rect) 3) 2))
  (list x y w))

(define (canopy-modal-render state rect frame)
  (define origin (canopy-modal-origin rect))
  (define x (list-ref origin 0))
  (define y (list-ref origin 1))
  (define w (list-ref origin 2))
  ;; the popup kit: elevated ui.popup backdrop, full-strength border, bold
  ;; title in the top edge (ui.background made the border invisible before)
  (define bg-style (theme-scope-ref "ui.popup"))
  (define popup-bg (style->bg bg-style))
  (define text-style
    (if popup-bg (style-bg (theme-scope-ref "ui.text") popup-bg) (theme-scope-ref "ui.text")))
  (define modal-area (area x y w 3))
  (buffer/clear-with frame modal-area bg-style)
  (block/render frame modal-area (make-block bg-style text-style "all" "rounded"))
  (when (> (string-length *canopy-modal-title*) 0)
    (frame-set-string! frame (+ x 2) y (string-append " " *canopy-modal-title* " ")
                        (style-with-bold text-style)))
  (define text (string-append *canopy-modal-label* *canopy-modal-buffer*))
  (frame-set-string! frame (+ x 1) (+ y 1) (canopy-truncate text (- w 2)) text-style))

(define (canopy-modal-cursor-fn state rect)
  (if (equal? *canopy-modal-mode* 'confirm)
      #f ; single keypress, no caret needed
      (let* ([origin (canopy-modal-origin rect)]
             [x (list-ref origin 0)]
             [y (list-ref origin 1)])
        (position (+ y 1) (+ x 1 (string-length *canopy-modal-label*) (string-length *canopy-modal-buffer*))))))

(define (canopy-modal-handle-event state event)
  (define ch (key-event-char event))
  (cond
    ;; the confirm branch below reads anything that isn't y as no, and a nudge of
    ;; the mouse shouldn't cancel the prompt it is sitting in front of
    [(mouse-event? event) event-result/consume]
    [(equal? *canopy-modal-mode* 'confirm)
     (define cb *canopy-modal-callback*)
     (set! *canopy-modal-callback* #f)
     (set! *canopy-modal-open?* #f)
     (when cb (enqueue-thread-local-callback (lambda () (cb (and (char? ch) (equal? ch #\y))))))
     event-result/close]
    [(key-event-enter? event)
     (define result *canopy-modal-buffer*)
     (define cb *canopy-modal-callback*)
     (set! *canopy-modal-callback* #f)
     (set! *canopy-modal-open?* #f)
     (when cb (enqueue-thread-local-callback (lambda () (cb result))))
     event-result/close]
    [(key-event-escape? event)
     (set! *canopy-modal-callback* #f)
     (set! *canopy-modal-open?* #f)
     event-result/close]
    [(key-event-backspace? event)
     (define len (string-length *canopy-modal-buffer*))
     (when (> len 0)
       (set! *canopy-modal-buffer* (substring *canopy-modal-buffer* 0 (- len 1))))
     event-result/consume]
    [(char? ch)
     (set! *canopy-modal-buffer* (string-append *canopy-modal-buffer* (string ch)))
     event-result/consume]
    [else event-result/consume]))

(define (canopy-show-modal! mode title label initial-value callback)
  (set! *canopy-modal-open?* #t)
  (set! *canopy-modal-mode* mode)
  (set! *canopy-modal-title* title)
  (set! *canopy-modal-label* label)
  (set! *canopy-modal-buffer* initial-value)
  (set! *canopy-modal-callback* callback)
  (push-component!
   (new-component! "canopy-modal"
                   (CanopyModalState)
                   canopy-modal-render
                   (hash "handle_event" canopy-modal-handle-event
                         "cursor" canopy-modal-cursor-fn))))

;; shell helpers: steel has no rename/copy builtins, so file ops shell out
(define (canopy-string-join parts sep)
  (if (null? parts)
      ""
      (let loop ([rest (cdr parts)] [acc (car parts)])
        (if (null? rest) acc (loop (cdr rest) (string-append acc sep (car rest)))))))

(define (canopy-shell-single-quote s)
  (string-append "'" (canopy-string-join (split-many s "'") "'\\''") "'"))

(define (canopy-run-sh! script err-label)
  (let ([proc (~> (command "sh" (list "-c" script))
                  with-stdout-piped
                  with-stderr-piped
                  spawn-process)])
    (if (Ok? proc)
        (let ([stderr (read-port-to-string (child-stderr (Ok->value proc)))])
          (when (not (string=? (trim stderr) ""))
            (error (trim stderr))))
        (error (string-append err-label ": could not spawn process")))))

;; first available of wl-copy / xclip / pbcopy gets the text
(define (canopy-copy-to-clipboard! text)
  (canopy-run-sh!
   (string-append "printf '%s' " (canopy-shell-single-quote text)
                  " | { wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null"
                  " || pbcopy 2>/dev/null; }")
   "clipboard"))

(define (canopy-run-cp! from-path to-path)
  (canopy-run-sh!
   (string-append "cp -r " (canopy-shell-single-quote from-path) " "
                  (canopy-shell-single-quote to-path))
   "cp"))

;; moves the entry to the system trash; #f when no trash tool exists
(define (canopy-try-trash! path)
  (with-handler
    (lambda (_) #f)
    (begin
      (canopy-run-sh!
       (string-append "T=" (canopy-shell-single-quote path)
                      "; trash \"$T\" 2>/dev/null || trash-put \"$T\" 2>/dev/null"
                      " || gio trash \"$T\" 2>/dev/null || echo 'no trash tool' >&2")
       "trash")
      #t)))

(define (canopy-run-mv! from-path to-path)
  (let ([proc (~> (command "mv" (list from-path to-path))
                  with-stdout-piped
                  with-stderr-piped
                  spawn-process)])
    (if (Ok? proc)
        (let ([stderr (read-port-to-string (child-stderr (Ok->value proc)))])
          (when (not (string=? (trim stderr) ""))
            (error (trim stderr))))
        (error "mv: could not spawn process"))))

(define (canopy-run-mkdir-p! path)
  (let ([proc (~> (command "mkdir" (list "-p" path))
                  with-stdout-piped
                  with-stderr-piped
                  spawn-process)])
    (if (Ok? proc)
        (let ([stderr (read-port-to-string (child-stderr (Ok->value proc)))])
          (when (not (string=? (trim stderr) ""))
            (error (trim stderr))))
        (error "mkdir: could not spawn process"))))

(define (canopy-run-touch! path)
  (let ([proc (~> (command "touch" (list path))
                  with-stdout-piped
                  with-stderr-piped
                  spawn-process)])
    (if (Ok? proc)
        (let ([stderr (read-port-to-string (child-stderr (Ok->value proc)))])
          (when (not (string=? (trim stderr) ""))
            (error (trim stderr))))
        (error "touch: could not spawn process"))))

(define (canopy-prompt-create!)
  (define entry (canopy-current-entry))
  (when entry
    (define path (car entry))
    (define base (if (is-dir? path)
                      (string-append path (path-separator))
                      (trim-end-matches path (file-name path))))
    (enqueue-thread-local-callback
     (lambda ()
       (canopy-show-modal!
        'input
        "New"
        (string-append "New (end with " (path-separator) " for dir): ")
        (canopy-relpath base)
        (lambda (name)
          (define full (string-append (canopy-root) (path-separator) name))
          (with-handler
            (lambda (err) (canopy-error (string-append "create failed: " (error-object-message err))))
            (begin
              (if (ends-with? name (path-separator))
                  (canopy-run-mkdir-p! full)
                  (begin
                    (canopy-run-mkdir-p! (canopy-parent-path full))
                    (canopy-run-touch! full)
                    (helix.open full)))
              (canopy-info (string-append "created " name))))
          (enqueue-thread-local-callback canopy-refresh-all!)))))))

(define (canopy-prompt-rename!)
  (define entry (canopy-current-entry))
  (when entry
    (define path (car entry))
    (define name (file-name path))
    (define dir (trim-end-matches path (string-append (path-separator) name)))
    (enqueue-thread-local-callback
     (lambda ()
       (canopy-show-modal!
        'input
        "Rename"
        "Rename: "
        name
        (lambda (new-name)
          (when (and (not (equal? new-name "")) (not (equal? new-name name)))
            (with-handler
              (lambda (err) (canopy-error (string-append "rename failed: " (error-object-message err))))
              (begin
                (canopy-run-mv! path (string-append dir (path-separator) new-name))
                (canopy-repath-open-buffer! path (string-append dir (path-separator) new-name))
                (canopy-info (string-append "renamed " name " -> " new-name))))
            (enqueue-thread-local-callback canopy-refresh-all!))))))))

;; after a rename/move, swap any clean open buffer over to the new path; a
;; dirty buffer is left alone (writing it would silently recreate the old path,
;; so the user gets a warning instead)
(define (canopy-repath-open-buffer! old-path new-path)
  (with-handler
    (lambda (_) void)
    (let ([doc (findf (lambda (d) (equal? old-path (editor-document->path d)))
                      (editor-all-documents))])
      (when doc
        (if (editor-document-dirty? doc)
            (canopy-info "renamed file has unsaved buffer changes; save them to the new path manually")
            (begin
              (helix.open new-path)
              (helix.buffer-close old-path)))))))

;; move: like rename but edits the workspace-relative path, so the entry can
;; change directory; missing target dirs are created
(define (canopy-prompt-move!)
  (define entry (canopy-current-entry))
  (when entry
    (define path (car entry))
    (define rel (canopy-relpath path))
    (enqueue-thread-local-callback
     (lambda ()
       (canopy-show-modal!
        'input
        "Move"
        "Move to: "
        rel
        (lambda (new-rel)
          (when (and (not (equal? new-rel "")) (not (equal? new-rel rel)))
            (define full (string-append (canopy-root) (path-separator) new-rel))
            (with-handler
              (lambda (err) (canopy-error (string-append "move failed: " (error-object-message err))))
              (begin
                (canopy-run-mkdir-p! (canopy-parent-path full))
                (canopy-run-mv! path full)
                (canopy-repath-open-buffer! path full)
                (canopy-info (string-append "moved " rel " -> " new-rel))))
            (enqueue-thread-local-callback canopy-refresh-all!))))))))

(define (canopy-delete-recursive! path)
  (if (is-dir? path)
      (begin
        (for-each canopy-delete-recursive!
                  (with-handler (lambda (_) '()) (read-dir path)))
        (delete-directory! path))
      (delete-file! path)))

(define (canopy-prompt-delete!)
  (define entry (canopy-current-entry))
  (when entry
    (define path (car entry))
    (define name (file-name path))
    (define kind (if (is-dir? path) "directory" "file"))
    (enqueue-thread-local-callback
     (lambda ()
       (canopy-show-modal!
        'confirm
        "Delete"
        (string-append "Delete " kind " '" name "'? (y/N) ")
        ""
        (lambda (confirmed?)
          (when confirmed?
            (with-handler
              (lambda (err) (canopy-error (string-append "delete failed: " (error-object-message err))))
              (if (and (not (equal? *canopy-use-trash* 'never)) (canopy-try-trash! path))
                  (canopy-info (string-append "trashed " name))
                  (begin
                    (canopy-delete-recursive! path)
                    (canopy-info (string-append "deleted " name)))))
            (enqueue-thread-local-callback canopy-refresh-all!))))))))

(struct CanopyBgState ())

;; panel's left edge is 0 when left else put against the right edge
(define (canopy-panel-x0 rect w)
  (if (equal? *canopy-side* 'right) (- (area-width rect) w) 0))

;; row 0 belongs to the bufferline, but with bufferline = "multiple" helix only
;; draws it for >1 open documents; reserving it unconditionally leaves a hole
(define (canopy-snacks-y0)
  (if (> (length (editor-all-documents)) 1) 1 0))

(define *canopy-query-prefix* "/ ")

(define (canopy-match-positions name query)
  (let loop ([ns (string->list (string-downcase name))]
             [qs (string->list (string-downcase query))]
             [i 0]
             [acc '()])
    (cond
      [(or (null? qs) (null? ns)) (reverse acc)]
      [(char=? (car ns) (car qs)) (loop (cdr ns) (cdr qs) (+ i 1) (cons i acc))]
      [else (loop (cdr ns) qs (+ i 1) acc)])))

(define (canopy-match-style base)
  (define c (style->fg (theme-scope-ref "special")))
  (style-with-bold (if c (style-fg base c) base)))

(define (canopy-render-name-hl frame x y name avail base-style match-style positions)
  (define truncated (canopy-truncate name avail))
  (define tlen (string-length truncated))
  (define pset (let loop ([ps positions] [acc (hashset)])
                 (if (null? ps) acc (loop (cdr ps) (hashset-insert acc (car ps))))))
  (let loop ([i 0])
    (when (< i tlen)
      (define on? (hashset-contains? pset i))
      (define j (let scan ([k (+ i 1)])
                  (if (and (< k tlen) (equal? (hashset-contains? pset k) on?)) (scan (+ k 1)) k)))
      (frame-set-string! frame (+ x i) y (substring truncated i j) (if on? match-style base-style))
      (loop j))))

;; inserts one matched relative path into the merged ancestor tree
(define (canopy-search-tree-insert node segs)
  (define seg (car segs))
  (define rest (cdr segs))
  (if (null? rest)
      (hash-insert node seg #t)
      (let* ([existing (hash-try-get node seg)]
             [child (if (hash? existing) existing (hash))])
        (hash-insert node seg (canopy-search-tree-insert child rest)))))

(define (canopy-search-build-tree matches)
  (let loop ([ms matches] [root (hash)])
    (if (null? ms)
        root
        (loop (cdr ms) (canopy-search-tree-insert root (split-many (car ms) (path-separator)))))))

;; depth 0 sits flush like the normal browsing view, nested levels are just indented
(define (canopy-search-flatten node path depth)
  (define keys (hash-keys->list node))
  (define dirs (sort (filter (lambda (k) (hash? (hash-try-get node k))) keys) string<?))
  (define files (sort (filter (lambda (k) (not (hash? (hash-try-get node k)))) keys) string<?))
  (define ordered (append dirs files))
  (let loop ([items ordered])
    (if (null? items)
        '()
        (let* ([name (car items)]
               [val (hash-try-get node name)]
               [dir? (hash? val)]
               [own (canopy-repeat-str "  " depth)]
               [rel (if (equal? path "") name (string-append path (path-separator) name))]
               [entry (list own dir? name rel)])
          (append (list entry)
                  (if dir? (canopy-search-flatten val rel (+ depth 1)) '())
                  (loop (cdr items)))))))

;; mouse kinds are bare integers; helix/components.scm documents the full table
(define *canopy-mouse-left-down* 0)
(define *canopy-mouse-left-up* 3)
(define *canopy-mouse-scroll-down* 10)
(define *canopy-mouse-scroll-up* 11)

(define *canopy-scroll-amount* 1) ; entries per wheel notch

(define (canopy-mouse-kind? event kind)
  (and (mouse-event? event) (equal? (event-mouse-kind event) kind)))

(define (canopy-mouse-left-down? event)
  (canopy-mouse-kind? event *canopy-mouse-left-down*))

(define (canopy-mouse-left-up? event)
  (canopy-mouse-kind? event *canopy-mouse-left-up*))

;; acting on the press would let the drag and release through to the buffer, so
;; clicks act on the release and have to land where the press did
(define *canopy-press* #f)

(define (canopy-press! target)
  (set! *canopy-press* target))

(define (canopy-take-press!)
  (define pressed *canopy-press*)
  (set! *canopy-press* #f)
  pressed)

;; 'up, 'down, or #f when this isn't a wheel event
(define (canopy-mouse-scroll-direction event)
  (cond
    [(canopy-mouse-kind? event *canopy-mouse-scroll-up*) 'up]
    [(canopy-mouse-kind? event *canopy-mouse-scroll-down*) 'down]
    [else #f]))

;; components.scm has mouse-event-within-area?, but it excludes the top row of an
;; area, which would make the first entry of every panel unclickable
(define (canopy-mouse-in-area? event a)
  (and a
       (mouse-event? event)
       (let ([row (event-mouse-row event)]
             [col (event-mouse-col event)])
         (and (>= col (area-x a)) (< col (+ (area-x a) (area-width a)))
              (>= row (area-y a)) (< row (+ (area-y a) (area-height a)))))))

;; recorded while rendering: the geometry depends on state the handler can't see
;; (reserved bars, the flattened search tree, column fitting)
(define *canopy-hit-panel* #f)   ; area of the whole sidebar
(define *canopy-hit-search* #f)  ; area of the search box above the entries
(define *canopy-hit-list* #f)    ; area of just its entry rows
;; one slot per visible row: an index into *canopy-tree* while browsing, a
;; workspace-relative path while searching, or #f for an unselectable row
(define *canopy-hit-rows* '())
(define *canopy-hit-window* 0) ; first result row on screen, while searching

(define (canopy-hit-row-at event)
  (and (canopy-mouse-in-area? event *canopy-hit-list*)
       (let ([row (- (event-mouse-row event) (area-y *canopy-hit-list*))])
         (and (>= row 0)
              (< row (length *canopy-hit-rows*))
              (list-ref *canopy-hit-rows* row)))))

;; resolves a recorded slot to a cursor position, or #f if it can't be selected
(define (canopy-hit-cursor-for slot)
  (cond
    [(int? slot) (and (< slot (length *canopy-tree*)) slot)]
    [(string? slot)
     (let loop ([rs *canopy-search-results*] [i 0])
       (cond
         [(null? rs) #f]
         [(equal? (car rs) slot) i]
         [else (loop (cdr rs) (+ i 1))]))]
    [else #f]))

;; what a press or release landed on, so the two can be compared
(define (canopy-click-target event)
  (define slot (canopy-hit-row-at event))
  (cond
    [slot (list 'row slot)]
    [(canopy-mouse-in-area? event *canopy-hit-search*) 'search]
    ;; the row padding and search headings are panel too, they just aren't rows
    [(canopy-mouse-in-area? event *canopy-hit-panel*) 'panel]
    [else 'buffer]))

;; the row the last click landed on, so a second one activates it without a timer
;; the cursor won't do: it can already be sitting on the row the first click hits
(define *canopy-click-slot* #f)

;; results and mini columns center on the selection as they render, sliding the
;; clicked row out from under the pointer, so the window is held while it stays armed
(define *canopy-click-window* #f)      ; snacks search: first row of the window
(define *canopy-mini-click-window* #f) ; mini: (column window-start)

(define (canopy-forget-click!)
  (set! *canopy-click-slot* #f)
  (set! *canopy-click-window* #f)
  (set! *canopy-mini-click-window* #f))

(define (canopy-arm-click! slot)
  (set! *canopy-click-slot* slot))

;; a keypress ends any gesture and stales whatever was armed
(define (canopy-reset-mouse!)
  (canopy-forget-click!)
  (set! *canopy-press* #f))

;; a click in the tree leaves the query being typed, selectable row or not, but one
;; in the search box is aiming at the query
(define (canopy-leave-typing-on-click! event)
  (when (canopy-mouse-in-area? event *canopy-hit-list*)
    (set! *canopy-typing?* #f)))

;; no-op if the slot fell out of the tree since it was recorded
(define (canopy-select-clicked! slot)
  (define cursor (canopy-hit-cursor-for slot))
  (when cursor
    (set! *canopy-cursor* cursor)
    (canopy-arm-click! slot)
    ;; browse mode scrolls independently of the cursor and needs no pinning
    (when (canopy-searching?) (set! *canopy-click-window* *canopy-hit-window*))))

;; single click acts: a folder toggles, a file opens
(define (canopy-mouse-select! slot)
  (define cursor (canopy-hit-cursor-for slot))
  (cond
    [cursor
     (set! *canopy-cursor* cursor)
     ;; no arming: the row acted immediately, and toggling reshuffles the tree
     (canopy-forget-click!)
     (canopy-activate!)]
    [else event-result/consume]))

;; cursor-up!/down! handle the window, so a notch is just repeated steps
;; a short list doesn't shift under the pointer, so the arm goes with it
(define (canopy-scroll-by! direction amount)
  (canopy-forget-click!)
  (let loop ([n amount])
    (when (> n 0)
      (if (equal? direction 'up) (canopy-cursor-up!) (canopy-cursor-down!))
      (loop (- n 1)))))

(define *canopy-scroll-pending* #f)

(define (canopy-debounce-scroll! action-thunk)
  (unless *canopy-scroll-pending*
    (set! *canopy-scroll-pending* #t) ;; close event gate
    (action-thunk) ;; apply scroll
    (enqueue-thread-local-callback
     (lambda () (set! *canopy-scroll-pending* #f))))) ;; reopen gate

(define (canopy-render-bg state rect frame)
  (define w (min *canopy-width* (area-width rect)))
  (define h (area-height rect))
  (define x0 (canopy-panel-x0 rect w))
  ;; one blank row above the search box
  (define y0 (canopy-snacks-y0))
  (define panel-h (max 1 (- h y0)))
  (set! *canopy-visible-height* (max 1 (- panel-h (canopy-search-height-now))))
  ;; follow the focused buffer: reveal it whenever it changes while the tree
  ;; itself is not being driven
  (when (and *canopy-auto-reveal* *canopy-active* (not *canopy-focused*)
             (not (canopy-searching?)))
    (define active (with-handler (lambda (_) #f)
                     (editor-document->path (editor->doc-id (editor-focus)))))
    (when (and (string? active) (not (equal? active *canopy-last-active-path*)))
      (set! *canopy-last-active-path* active)
      (enqueue-thread-local-callback canopy-reveal-current-file!)))
  (if *canopy-active*
      (begin
        (if (equal? *canopy-side* 'right)
            (set-editor-clip-right! w)
            (set-editor-clip-left! w))
        (canopy-publish-clip! *canopy-side* w))
      (canopy-clear-clip!))

  ;; theme components a configured sidebar background tints only these panel
  ;; styles, so the buffer keeps the theme background
  (define panel-bg (canopy-panel-bg-color))
  (define (canopy-with-panel-bg s) (if panel-bg (style-bg s panel-bg) s))
  (define bg-style (canopy-with-panel-bg (theme-scope-ref "ui.background")))
  (define text-style (canopy-with-panel-bg (theme-scope-ref "ui.text")))
  ;; the selection and the title dim while the editor holds focus
  (define hl-base (theme-scope-ref "ui.menu.selected"))
  (define hl-style (if *canopy-focused* hl-base (style-with-dim hl-base)))
  (define dir-style (canopy-with-panel-bg (theme-scope-ref "ui.text.info")))
  (define dim-style (canopy-with-panel-bg (style-with-dim (theme-scope-ref "ui.text"))))
  (define guide-style (canopy-with-panel-bg (style-with-dim (theme-scope-ref "ui.virtual.indent-guide"))))

  ;; header band: the root row doubles as the panel's title bar (menu shade,
  ;; changed-file count at the right edge); selection styling still wins
  (define band-bg (style->bg (theme-scope-ref "ui.menu")))
  ;; count only what lives under the current root, so a dive's header agrees
  ;; with its rows; relpath == root means the root IS the repo toplevel
  (define changed-count
    (let ([keys (hash-keys->list *canopy-git-status-map*)]
          [rel (canopy-git-relpath (canopy-root))])
      (if (equal? rel (canopy-root))
          (length keys)
          (let ([prefix (string-append rel "/")])
            (length (filter (lambda (k) (starts-with? k prefix)) keys))))))
  (define title-style (if *canopy-focused* (style-with-bold dir-style) dim-style))

  ;; no border for cleaner look
  (define panel-area (area x0 y0 w panel-h))
  (buffer/clear-with frame panel-area bg-style)

  ;; border matches bg so it blends in instead of clashing across themes;
  (define border-style bg-style)

  ;; on the divider side reserve the last column for the line
  ;; entries stay flush left and fill up to one gap column before it
  (define left-divider? (and *canopy-show-separator?* (not (equal? *canopy-side* 'right))))
  (define list-w (if left-divider? (- w 2) w))
  ;; the search box is centered between the left edge and the divider
  (define box-x (if left-divider? (+ x0 1) x0))
  (define box-w (if left-divider? (- w 3) w))

  (define search-h (canopy-search-height-now))
  (define search-area (area box-x y0 box-w search-h))
  (when (> search-h 0)
    ;; outline color marks focus
    (define search-line (canopy-search-color))
    (define search-border-style
      (if search-line
          (style-fg bg-style search-line)
          (canopy-with-panel-bg (theme-scope-ref "ui.text"))))
    (block/render frame search-area (make-block bg-style search-border-style "all" "rounded"))

    ;; a small search glyph sits in the top border; the counter cuts into its
    ;; right corner, so the input row stays clean for the query alone
    (when (> box-w 6)
      (frame-set-string! frame (+ box-x 2) y0 " 󰍉 " title-style))

    (frame-set-string! frame (+ box-x 1) (+ y0 1) *canopy-query-prefix* title-style)
    (define query-shown
      (canopy-truncate *canopy-query* (- box-w 2 (string-length *canopy-query-prefix*))))
    (frame-set-string! frame (+ box-x 1 (string-length *canopy-query-prefix*)) (+ y0 1)
                        query-shown text-style)

    (when (canopy-searching?)
      (define counter (string-append " " (number->string (length *canopy-search-results*))
                                      "/" (number->string (length *canopy-all-files*)) " "))
      (define counter-x (- (+ box-x box-w) 2 (string-length counter)))
      (when (> counter-x (+ box-x 6))
        (frame-set-string! frame counter-x y0 counter dim-style))))

  (when *canopy-show-separator?*
    (define sep-x (if (equal? *canopy-side* 'right) (- x0 1) (- (+ x0 w) 1)))
    (define sep-top y0)
    (define sep-bottom (- (+ y0 panel-h) 1))
    (when (and (>= sep-x 0) (< sep-x (area-width rect)))
      (let loop ([y sep-top])
        (when (<= y sep-bottom)
          (frame-set-string! frame sep-x y "│" border-style)
          (loop (+ y 1))))))

  (define list-y0 (+ y0 search-h))
  (define max-text-w (- list-w 1))

  (set! *canopy-hit-panel* panel-area)
  (set! *canopy-hit-search* search-area)
  (set! *canopy-hit-list* (area x0 list-y0 w *canopy-visible-height*))
  (set! *canopy-hit-rows* '())

  (if (canopy-searching?)
      (if (null? *canopy-search-results*)
          (frame-set-string! frame (+ x0 1) list-y0 "(no matches)" dim-style)
          (let* ([tree (canopy-search-build-tree *canopy-search-results*)]
                 [rows (canopy-search-flatten tree "" 0)]
                 [selected-rel (list-ref *canopy-search-results* *canopy-cursor*)]
                 [selected-row (let loop ([rs rows] [i 0])
                                 (cond [(null? rs) 0]
                                       [(and (not (list-ref (car rs) 1)) (equal? (list-ref (car rs) 3) selected-rel)) i]
                                       [else (loop (cdr rs) (+ i 1))]))]
                 [total-rows (length rows)]
                 [window-start (max 0 (min (max 0 (- total-rows *canopy-visible-height*))
                                            (or *canopy-click-window*
                                                (max 0 (- selected-row (canopy-half-floor *canopy-visible-height*))))))]
                 [visible (canopy-take (canopy-drop rows window-start) *canopy-visible-height*)])
            ;; headings aren't selectable, so they record #f and a click does nothing
            (set! *canopy-hit-window* window-start)
            (set! *canopy-hit-rows*
                  (map (lambda (e) (if (list-ref e 1) #f (list-ref e 3))) visible))
            (let loop ([items visible] [row 0])
              (unless (or (null? items) (>= row *canopy-visible-height*))
                (define entry (car items))
                (define own-prefix (list-ref entry 0))
                (define dir? (list-ref entry 1))
                (define name (list-ref entry 2))
                (define rel (list-ref entry 3))
                (define icon (if dir? (glyph-dir-icon name) (canopy-file-icon name)))
                (define icon-color (if dir? (glyph-dir-color name) (canopy-file-color name)))
                (define git-status (and (not dir?) (canopy-git-status rel)))
                (define git-style (and git-status (canopy-with-panel-bg (canopy-git-scope git-status))))
                (define y (+ list-y0 row))
                (define hl? (and (not dir?) (equal? rel selected-rel)))
                (define row-style (cond [hl? hl-style]
                                        [dir? dir-style]
                                        [git-style git-style]
                                        [else text-style]))
                (define prefix-w (string-length own-prefix))
                (define icon-w (string-length icon))
                (define git-x (+ x0 prefix-w icon-w 1))
                (define git-w (if dir? 0 1))
                (define gap (if dir? 0 1))
                (define name-x (+ git-x git-w gap))
                (define avail (max 0 (- max-text-w prefix-w icon-w 1 git-w gap)))
                (define positions (and (not dir?) (canopy-match-positions name *canopy-query*)))
                (when hl?
                  (frame-set-string! frame x0 y (make-string list-w #\space) hl-style))
                (frame-set-string! frame x0 y own-prefix row-style)
                (frame-set-string! frame (+ x0 prefix-w) y icon (glyph-style icon-color #:base row-style))
                (unless dir?
                  (frame-set-string! frame git-x y (if git-status "●" " ")
                                      (if git-style git-style row-style)))
                (if (and positions (pair? positions))
                    (canopy-render-name-hl frame name-x y name avail row-style (canopy-match-style row-style) positions)
                    (frame-set-string! frame name-x y (canopy-truncate name avail) row-style))
                ;; same focus bar the tree rows carry
                (when (and hl? *canopy-focused*)
                  (frame-set-string! frame x0 y "▎" (style-with-bold dir-style)))
                (loop (cdr items) (+ row 1))))))
      (let ([visible (canopy-take (canopy-drop *canopy-tree* *canopy-window-start*)
                                   *canopy-visible-height*)])
        (set! *canopy-hit-rows*
              (let loop ([items visible] [i *canopy-window-start*])
                (if (null? items) '() (cons i (loop (cdr items) (+ i 1))))))
        (let loop ([items visible] [row 0])
          (unless (or (null? items) (>= row *canopy-visible-height*))
            (define entry (car items))
            (define abs-idx (+ *canopy-window-start* row))
            (define path (list-ref entry 0))
            (define indent (list-ref entry 1))
            (define marker (list-ref entry 2))
            (define name (list-ref entry 3))
            (define prefix (string-append indent marker))
            (define dir? (is-dir? path))
            (define icon (if dir? (glyph-dir-icon name) (canopy-file-icon name)))
            (define icon-color (if dir? (glyph-dir-color name) (canopy-file-color name)))
            (define git-status
              (if dir?
                  (and (canopy-dir-has-changes? path) 'modified)
                  (canopy-git-status path)))
            (define git-style (and git-status (canopy-with-panel-bg (canopy-git-scope git-status))))
            (define y (+ list-y0 row))
            (define hl? (= abs-idx *canopy-cursor*))
            (define root? (equal? path (canopy-root)))
            (define band? (and root? (not hl?) band-bg))
            (define row-style (let ([s (cond [hl? hl-style]
                                             [root? (style-with-bold dir-style)]
                                             [dir? dir-style]
                                             [git-style git-style]
                                             [else text-style])])
                                (if band? (style-bg s band-bg) s)))
            (define band-dim (if band? (style-bg dim-style band-bg) dim-style))
            (define indent-w (string-length indent))
            (define prefix-w (string-length prefix))
            (define icon-w (string-length icon))
            (define git-x (+ x0 prefix-w icon-w 1))
            (define git-w 1)
            (define gap 1)
            (define name-x (+ git-x git-w gap))
            ;; the band's right edge is reserved for the changed count
            (define count-w (if (and band? (> changed-count 0))
                                (+ 3 (string-length (number->string changed-count)))
                                0))
            (define avail (max 0 (- max-text-w prefix-w icon-w 1 git-w gap count-w)))
            (when (or hl? band?)
              (frame-set-string! frame x0 y (make-string list-w #\space)
                                  (if hl? hl-style (style-bg text-style band-bg))))
            ;; faint depth guides, dim chevron, then the icon / dot / name
            (frame-set-string! frame x0 y indent (if hl? hl-style guide-style))
            (frame-set-string! frame (+ x0 indent-w) y marker (if hl? hl-style band-dim))
            (frame-set-string! frame (+ x0 prefix-w) y icon (glyph-style icon-color #:base row-style))
            ;; on the band the count replaces the dot
            (frame-set-string! frame git-x y (if (and git-status (not band?)) "●" " ")
                                (cond [band? row-style]
                                      [git-style git-style]
                                      [else row-style]))
            (define crumb-w
              (if (and root? *canopy-root-override*)
                  ;; breadcrumb: dim parent context ahead of the bold root name
                  (let* ([crumb (string-append (file-name (canopy-parent-path path)) " › ")]
                         [crumb-shown (canopy-truncate crumb avail)])
                    (frame-set-string! frame name-x y crumb-shown
                                        (if hl? (style-with-dim hl-style) band-dim))
                    (frame-set-string! frame (+ name-x (string-length crumb-shown)) y
                                        (canopy-truncate name (max 0 (- avail (string-length crumb-shown))))
                                        row-style)
                    (string-length crumb-shown))
                  (begin
                    (frame-set-string! frame name-x y (canopy-truncate name avail) row-style)
                    0)))
            ;; symlinks carry their literal target, dim, after the name
            (define link-target (hash-try-get *canopy-symlink-map* path))
            (define link-w
              (if link-target
                  (let* ([shown-name-w (string-length (canopy-truncate name (max 0 (- avail crumb-w))))]
                         [suffix (canopy-truncate (string-append " → " link-target)
                                                   (max 0 (- avail crumb-w shown-name-w)))])
                    (frame-set-string! frame (+ name-x crumb-w shown-name-w) y suffix
                                        (if hl? (style-with-dim hl-style) band-dim))
                    (string-length suffix))
                  0))
            ;; expanded-but-empty dirs say so instead of silently flipping
            (when (and dir? (canopy-dir-expanded? path)
                       (let ([rest (cdr items)])
                         (or (null? rest)
                             (not (equal? (canopy-parent-path (car (car rest))) path)))))
              (define label-x (+ name-x crumb-w link-w (string-length name) 1))
              (when (< label-x (+ x0 max-text-w -7))
                (frame-set-string! frame label-x y "(empty)"
                                    (if hl? (style-with-dim hl-style) band-dim))))
            ;; band right edge: how many files git says changed
            (when (and band? (> changed-count 0))
              (define count-str (string-append "● " (number->string changed-count)))
              (define cx (max (+ x0 1) (- (+ x0 list-w) (string-length count-str) 1)))
              (frame-set-string! frame cx y count-str
                                  (style-bg (canopy-git-scope 'modified) band-bg)))
            ;; focus bar: instantly answers "does the tree own my keys?"
            (when (and hl? *canopy-focused*)
              (frame-set-string! frame x0 y "▎" (style-with-bold dir-style)))
            (loop (cdr items) (+ row 1)))))))

;; canopy-snacks-open! would reveal the current file and move off the clicked row
;; deferred since the compositor can't be restacked mid-dispatch
(define (canopy-refocus-from-click!)
  (unless *canopy-focused*
    (set! *canopy-focused* #t)
    (enqueue-thread-local-callback
     ;; a second fg would never be popped
     (lambda () (when *canopy-focused* (push-component! (canopy-make-fg-component)))))))

(define (canopy-handle-event-bg state event)
  ;; unfocused, so anything the mouse doesn't claim falls through to the editor
  (define dir (canopy-mouse-scroll-direction event))
  (cond
    ;; a key ends any gesture, so a lost release can't leave the panel eating clicks
    [(not (mouse-event? event))
     (canopy-reset-mouse!)
     event-result/ignore]
    ;; tested before the panel rect, since the gesture may have wandered off it
    [*canopy-press*
     (when (canopy-mouse-left-up? event)
       ;; select rather than activate, but arm the row so the next click opens it
       (define target (canopy-click-target event))
       (when (equal? target (canopy-take-press!))
         (canopy-leave-typing-on-click! event)
         (when (pair? target) (canopy-select-clicked! (cadr target)))
         (when (equal? target 'search) (set! *canopy-typing?* #t))
         (canopy-refocus-from-click!)))
     event-result/consume]
    [(not (canopy-mouse-in-area? event *canopy-hit-panel*)) event-result/ignore]
    [(canopy-mouse-left-down? event)
     (canopy-press! (canopy-click-target event))
     event-result/consume]
    [dir
     ;; scrolling over the panel reads as inspecting it, not entering it
     (canopy-debounce-scroll! (lambda () (canopy-scroll-by! dir *canopy-scroll-amount*)))
     (helix.redraw) ; unfocused, so consuming alone won't re-render
     event-result/consume]
    [else event-result/ignore]))

(struct CanopyFgState ())

(define (canopy-render-fg state rect frame) void) ; bg handles all drawing

;; ---- file preview popup -----------------------------------------------------
(define *canopy-preview?* #f)
(define *canopy-preview-path* #f)
(define *canopy-preview-lines* '())

(define (canopy-preview-toggle!)
  (set! *canopy-preview?* (not *canopy-preview?*))
  (unless *canopy-preview?*
    (set! *canopy-preview-path* #f)
    (set! *canopy-preview-lines* '())))

(define (canopy-preview-load! path)
  (unless (equal? path *canopy-preview-path*)
    (set! *canopy-preview-path* path)
    (set! *canopy-preview-lines*
          (cond
            [(not path) '()]
            [(is-dir? path)
             (with-handler (lambda (_) (list "<unreadable>"))
               (map (lambda (p) (string-append (if (is-dir? p) " " " ") (file-name p)))
                    (sort (read-dir path) string<?)))]
            [(canopy-binary-path? path) (list "<binary file>")]
            [else
             (with-handler
               (lambda (_) (list "<unreadable>"))
               (let ([proc (~> (command "head" (list "-n" "60" path))
                               with-stdout-piped
                               with-stderr-piped
                               spawn-process)])
                 (if (Ok? proc)
                     ;; the final newline is a terminator, not an empty line
                     (let ([ls (split-many (read-port-to-string (child-stdout (Ok->value proc))) "\n")])
                       (if (and (pair? ls) (equal? (list-ref ls (- (length ls) 1)) ""))
                           (reverse (cdr (reverse ls)))
                           ls))
                     (list "<unreadable>"))))]))))

(define (canopy-preview-render! rect frame)
  (when (and *canopy-active* *canopy-focused* *canopy-preview?*)
    (define entry (canopy-current-entry))
    (canopy-preview-load! (and entry (car entry)))
    (when (and entry (not (null? *canopy-preview-lines*)))
      (define panel-w (min *canopy-width* (area-width rect)))
      (define right-side? (equal? *canopy-side* 'right))
      (define avail-w (- (area-width rect) panel-w 2))
      (define box-w (min 82 (max 20 avail-w)))
      (define box-x (if right-side?
                        (max 0 (- (area-width rect) panel-w box-w 1))
                        (+ panel-w 1)))
      (define box-h (min (+ 2 (length *canopy-preview-lines*))
                         (max 5 (- (area-height rect) 4))))
      (define box-y 1)
      (when (> avail-w 20)
        (define bgp (theme-scope-ref "ui.popup"))
        (define pbg (style->bg bgp))
        ;; content in real text styling; bare ui.popup often has no fg
        (define ptext (if pbg (style-bg (theme-scope-ref "ui.text") pbg) (theme-scope-ref "ui.text")))
        (define box-area (area box-x box-y box-w box-h))
        (buffer/clear-with frame box-area bgp)
        (block/render frame box-area (make-block bgp ptext "all" "rounded"))
        (frame-set-string! frame (+ box-x 2) box-y
                            (string-append " " (canopy-truncate (file-name (car entry)) (- box-w 6)) " ")
                            (style-with-bold ptext))
        (let loop ([ls *canopy-preview-lines*] [row 1])
          (cond
            [(or (null? ls) (>= row (- box-h 1))) void]
            [(and (= row (- box-h 2)) (> (length ls) 1))
             ;; more content than rows: say so instead of cutting silently
             (frame-set-string! frame (+ box-x 1) (+ box-y row) "…" (style-with-dim ptext))]
            [else
             (frame-set-string! frame (+ box-x 1) (+ box-y row)
                                 (canopy-truncate (car ls) (- box-w 2)) ptext)
             (loop (cdr ls) (+ row 1))]))))))

(define (canopy-render-bg+preview state rect frame)
  (canopy-render-bg state rect frame)
  (canopy-preview-render! rect frame))

;; cursor only needs to appear while actively typing a search query
(define (canopy-cursor-fn-fg state area)
  (if *canopy-typing?*
      (let* ([w (min *canopy-width* (area-width area))]
             [x0 (canopy-panel-x0 area w)]
             [box-x (if (and *canopy-show-separator?* (not (equal? *canopy-side* 'right)))
                        (+ x0 1) x0)])
        (position (+ (canopy-snacks-y0) 1)
                  (+ box-x 1 (string-length *canopy-query-prefix*) (string-length *canopy-query*))))
      #f))

(define (canopy-handle-event-typing state event)
  (define ch (key-event-char event))
  (cond
    [(key-event-enter? event)
     ;; confirms the query without opening anything, so the matches can
     ;; still be browsed with j/k before committing to one with a second enter
     (set! *canopy-typing?* #f)
     event-result/consume]
    [(key-event-escape? event)
     ;; abandons the search: clear the query and restore the pre-search tree
     (canopy-search-restore!)
     event-result/consume]
    [(key-event-backspace? event)
     (canopy-backspace!)
     event-result/consume]
    [(char? ch)
     (canopy-type! ch)
     event-result/consume]
    [else event-result/consume]))

(define *canopy-yank-path* #f)

(define (canopy-yank!)
  (define entry (canopy-current-entry))
  (when entry
    (set! *canopy-yank-path* (car entry))
    (canopy-info (string-append "yanked " (canopy-relpath (car entry))))))

;; copies the yanked entry into the dir under the cursor (or the cursor's parent)
(define (canopy-paste!)
  (define entry (canopy-current-entry))
  (cond
    [(not *canopy-yank-path*) (canopy-info "canopy: nothing yanked")]
    [(not entry) void]
    [else
     (define target-dir (if (is-dir? (car entry)) (car entry) (canopy-parent-path (car entry))))
     (define dest (string-append target-dir (path-separator) (file-name *canopy-yank-path*)))
     (cond
       [(or (is-file? dest) (is-dir? dest))
        (canopy-error (string-append "paste: " (canopy-relpath dest) " already exists"))]
       [else
        (with-handler
          (lambda (err) (canopy-error (string-append "paste failed: " (error-object-message err))))
          (begin
            (canopy-run-cp! *canopy-yank-path* dest)
            (canopy-info (string-append "pasted " (canopy-relpath dest)))))
        (canopy-refresh-all!)])]))

(define (canopy-copy-path!)
  (define entry (canopy-current-entry))
  (when entry
    (with-handler
      (lambda (err) (canopy-error (string-append "copy path failed: " (error-object-message err))))
      (begin
        (canopy-copy-to-clipboard! (car entry))
        (canopy-info (string-append "copied path " (car entry)))))))

;; ---- tree root -------------------------------------------------------------
;; the tree normally follows the helix workspace; > dives into a subdir as
;; the new root and < climbs back out
(define *canopy-root-override* #f)

(define (canopy-root)
  (or *canopy-root-override* (helix-find-workspace)))

(define (canopy-set-root! path)
  ;; climbing back to the workspace clears the override, so the breadcrumb
  ;; disappears and the pristine state is reachable again
  (set! *canopy-root-override*
        (if (equal? path (helix-find-workspace)) #f path))
  ;; the new root always shows expanded
  (set! *canopy-directories* (hash-insert *canopy-directories* path #f))
  (set! *canopy-cursor* 0)
  (set! *canopy-window-start* 0)
  (set! *canopy-query* "")
  (set! *canopy-typing?* #f)
  (canopy-load-state!)
  (canopy-refresh-all!)
  (canopy-info (string-append "root: " (canopy-root))))

(define (canopy-root-dive!)
  (define entry (canopy-current-entry))
  (when (and entry (not (canopy-searching?)))
    (define target (if (is-dir? (car entry)) (car entry) (canopy-parent-path (car entry))))
    (when (and (string? target) (not (equal? target (canopy-root))))
      (canopy-set-root! target))))

(define (canopy-root-up!)
  (define parent (canopy-parent-path (canopy-root)))
  (when (and (string? parent) (> (string-length parent) 1) (not (equal? parent (canopy-root))))
    (canopy-set-root! parent)))

;; ---- session persistence ---------------------------------------------------
;; expanded dirs survive restarts, one state file per root under
;; $HOME/.local/state/canopy
(define *canopy-state-loaded-root* #f)

(define (canopy-state-path-sh)
  (string-append "\"$HOME/.local/state/canopy/"
                 (canopy-string-join (split-many (canopy-root) "/") "%") ".list\""))

(define (canopy-expanded-relpaths)
  (let loop ([ks (hash-keys->list *canopy-directories*)] [acc '()])
    (cond
      [(null? ks) acc]
      [(canopy-dir-expanded? (car ks)) (loop (cdr ks) (cons (canopy-relpath (car ks)) acc))]
      [else (loop (cdr ks) acc)])))

(define (canopy-save-state!)
  (with-handler
    (lambda (_) void)
    (canopy-run-sh!
     (string-append "mkdir -p \"$HOME/.local/state/canopy\" && printf '%s' "
                    (canopy-shell-single-quote (canopy-string-join (canopy-expanded-relpaths) "\n"))
                    " > " (canopy-state-path-sh))
     "state")))

(define (canopy-load-state!)
  (unless (equal? *canopy-state-loaded-root* (canopy-root))
    (set! *canopy-state-loaded-root* (canopy-root))
    (with-handler
      (lambda (_) void)
      (let ([proc (~> (command "sh" (list "-c" (string-append "cat " (canopy-state-path-sh) " 2>/dev/null")))
                      with-stdout-piped
                      with-stderr-piped
                      spawn-process)])
        (when (Ok? proc)
          (let* ([out (read-port-to-string (child-stdout (Ok->value proc)))]
                 [rels (filter (lambda (l) (> (string-length l) 0)) (split-many out "\n"))])
            (for-each
             (lambda (rel)
               (define full (string-append (canopy-root) (path-separator) rel))
               (when (is-dir? full)
                 (set! *canopy-directories* (hash-insert *canopy-directories* full #f))))
             rels)))))))

(define (canopy-command-action! action)
  (cond
    [(equal? action 'down) (canopy-cursor-down!) event-result/consume]
    [(equal? action 'up) (canopy-cursor-up!) event-result/consume]
    [(equal? action 'enter) (canopy-enter-or-open!)]
    [(equal? action 'back) (canopy-goto-parent!) event-result/consume]
    [(equal? action 'search) (canopy-enter-search!) event-result/consume]
    [(equal? action 'create) (canopy-prompt-create!) event-result/consume]
    [(equal? action 'rename) (canopy-prompt-rename!) event-result/consume]
    [(equal? action 'delete) (canopy-prompt-delete!) event-result/consume]
    [(equal? action 'refresh) (canopy-refresh-all!) event-result/consume]
    [(equal? action 'bottom)
     (unless (canopy-searching?) (canopy-cursor-linear! (length *canopy-tree*)))
     event-result/consume]
    [(equal? action 'move) (canopy-prompt-move!) event-result/consume]
    [(equal? action 'reveal) (canopy-reveal-current-file!) event-result/consume]
    [(equal? action 'yank) (canopy-yank!) event-result/consume]
    [(equal? action 'paste) (canopy-paste!) event-result/consume]
    [(equal? action 'copy-path) (canopy-copy-path!) event-result/consume]
    [(equal? action 'root-dive) (canopy-root-dive!) event-result/consume]
    [(equal? action 'root-up) (canopy-root-up!) event-result/consume]
    [(equal? action 'preview) (canopy-preview-toggle!) event-result/consume]
    [(equal? action 'toggle-hidden) (canopy-toggle-hidden!) event-result/consume]
    [(equal? action 'toggle-git-ignored) (canopy-toggle-git-ignored!) event-result/consume]
    [(equal? action 'wider) (canopy-wider!) event-result/consume]
    [(equal? action 'narrower) (canopy-narrower!) event-result/consume]
    [(equal? action 'menu) (canopy-whichkey-open! 'snacks canopy-command-action!) event-result/consume]
    [(equal? action 'quit) (canopy-close!) event-result/consume]
    [else event-result/consume]))

(define (canopy-handle-event-command state event)
  (define ch (key-event-char event))
  (cond
    [(key-event-down? event) (canopy-cursor-down!) event-result/consume]
    [(key-event-up? event) (canopy-cursor-up!) event-result/consume]
    [(key-event-right? event) (canopy-enter-or-open!)]
    [(key-event-left? event) (canopy-goto-parent!) event-result/consume]
    [(key-event-enter? event) (canopy-activate!)]
    [(key-event-tab? event)
     (define entry (canopy-current-entry))
     (when (and entry (is-dir? (car entry))) (canopy-toggle-dir! (car entry)))
     event-result/consume]

    [(key-event-escape? event)
     ;; first escape leaves an active search, second leaves the tree
     (if (canopy-searching?)
         (begin (canopy-search-restore!) event-result/consume)
         (begin (canopy-switch-to-editor!) event-result/close))] ; close pops fg only; bg stays visible

    [(key-event-backspace? event)
     (canopy-clear-search!)
     event-result/consume]

    ;; ctrl chords canopy owns: half-page moves and split opens
    [(and (char? ch) (equal? (key-event-modifier event) key-modifier-ctrl))
     (cond
       [(char=? ch #\d)
        (unless (canopy-searching?)
          (canopy-cursor-linear! (canopy-half-floor *canopy-visible-height*)))
        event-result/consume]
       [(char=? ch #\u)
        (unless (canopy-searching?)
          (canopy-cursor-linear! (- (canopy-half-floor *canopy-visible-height*))))
        event-result/consume]
       [(char=? ch #\s) (canopy-open-current! 'horizontal)]
       [(char=? ch #\v) (canopy-open-current! 'vertical)]
       ;; C-h means "go left"; the tree is already leftmost, so stay put
       [(char=? ch #\h) event-result/consume]
       [else (canopy-switch-to-editor!) event-result/close])]

    ;; remaining ctrl/alt chords belong to the editor: hand focus back (like
    ;; Escape) instead of misreading the chord as its bare character
    [(let ([m (key-event-modifier event)])
       (not (or (equal? m #f) (equal? m 0) (equal? m key-modifier-shift))))
     (canopy-switch-to-editor!)
     event-result/close]

    ;; armed mini-leader: space f = file picker (focus follows via auto-reveal),
    ;; space e = toggle panel, space space (or anything else) = help
    [(and *canopy-pending-space* (char? ch))
     (set! *canopy-pending-space* #f)
     (set! *canopy-pending-g* #f)
     (cond
       [(char=? ch #\f)
        (canopy-switch-to-editor!)
        (enqueue-thread-local-callback file_picker)
        event-result/close]
       [(char=? ch #\e)
        (canopy-toggle)
        event-result/consume]
       [else (canopy-command-action! 'menu)])]

    [(and (char? ch) (char=? ch #\space))
     (set! *canopy-pending-g* #f)
     (set! *canopy-pending-space* #t)
     event-result/consume]

    [(and (char? ch) (equal? ch #\=)) (canopy-wider!) event-result/consume] ; old alias not remappable

    ;; gg jumps to the top; a lone g just arms the sequence
    [(and (char? ch) (char=? ch #\g))
     (if *canopy-pending-g*
         (begin
           (set! *canopy-pending-g* #f)
           (unless (canopy-searching?) (canopy-cursor-linear! (- (length *canopy-tree*)))))
         (set! *canopy-pending-g* #t))
     event-result/consume]

    [(and (char? ch) (char=? ch #\?)) (canopy-command-action! 'menu)] ; help alias

    ;; : opens the editor's command line (e.g. :qa!) instead of being swallowed
    [(and (char? ch) (char=? ch #\:))
     (canopy-switch-to-editor!)
     (enqueue-thread-local-callback command_mode)
     event-result/close]

    [(char? ch)
     (set! *canopy-pending-g* #f)
     (define action (canopy-action-for-char ch))
     (if action (canopy-command-action! action) event-result/consume)]

    [else event-result/consume])) ; block unknown keys from editor while focused

(define (canopy-handle-mouse-fg state event)
  (define dir (canopy-mouse-scroll-direction event))
  (cond
    [(canopy-mouse-left-down? event)
     (canopy-press! (canopy-click-target event))
     event-result/consume]
    [(canopy-mouse-left-up? event)
     (define target (canopy-click-target event))
     (cond
       [(not (equal? target (canopy-take-press!))) event-result/consume]
       [(pair? target)
        (canopy-leave-typing-on-click! event)
        (canopy-mouse-select! (cadr target))]
       ;; picks up wherever the query left off rather than starting a new one
       [(equal? target 'search)
        (set! *canopy-typing?* #t)
        event-result/consume]
       [(equal? target 'panel)
        (canopy-leave-typing-on-click! event)
        event-result/consume]
       ;; helix has already spent this event, so it takes another to place the caret
       [else
        (canopy-switch-to-editor!)
        event-result/close])]
    [dir
     (if (canopy-mouse-in-area? event *canopy-hit-panel*)
         (begin
           (canopy-debounce-scroll! (lambda () (canopy-scroll-by! dir *canopy-scroll-amount*)))
           event-result/consume)
         ;; let the buffer scroll under the pointer without losing the panel
         event-result/ignore)]
    ;; drags and bare movement would otherwise fall through to the editor
    [else event-result/consume]))

(define (canopy-handle-event-fg state event)
  (cond
    [*canopy-modal-open?* event-result/ignore]
    [*canopy-help-open?* event-result/ignore]
    ;; ahead of the typing branch so the tree stays clickable mid-query
    [(mouse-event? event) (canopy-handle-mouse-fg state event)]
    [else
     ;; any keypress can move the cursor, so an armed row stops meaning anything
     (canopy-reset-mouse!)
     (if *canopy-typing?*
         (canopy-handle-event-typing state event)
         (canopy-handle-event-command state event))]))

(define (canopy-make-bg-component)
  (new-component! "canopy-bg"
                  (CanopyBgState)
                  canopy-render-bg+preview
                  (hash "handle_event" canopy-handle-event-bg)))

(define (canopy-make-fg-component)
  (new-component! "canopy-fg"
                  (CanopyFgState)
                  canopy-render-fg
                  (hash "handle_event" canopy-handle-event-fg
                        "cursor" canopy-cursor-fn-fg)))

(define (canopy-snacks-open!)
  (cond
    [(not *canopy-active*)
     (set! *canopy-active* #t)
     (set! *canopy-focused* #t)
     (set! *canopy-cursor* 0)
     (set! *canopy-window-start* 0)
     (set! *canopy-query* "")
     (set! *canopy-search-results* '())
     (set! *canopy-typing?* #f)
     (canopy-scan-git-ignored! (canopy-root))
     (canopy-load-state!)
     (canopy-reveal-current-file!)
     (canopy-scan-files!)
     (push-component! (canopy-make-bg-component))
     (push-component! (canopy-make-fg-component))]

    [*canopy-focused*
     (canopy-switch-to-editor!)]

    [else
     ;; refocusing restores the last tree position; the auto-reveal detector
     ;; (buffer changes while unfocused) and the f key handle revealing
     (set! *canopy-focused* #t)
     (canopy-scan-git-ignored! (canopy-root))
     (push-component! (canopy-make-fg-component))]))

;; hx <directory> auto-opens the file picker before our deferred dock runs,
;; and the compositor is push-ordered, so the panel would paint over the
;; picker's left edge. Recreate the picker so it stacks above the tree.
(define *canopy-startup-handled* #f)

(define (canopy-launched-with-directory?)
  (let loop ([args (cdr (command-line))])
    (cond
      [(null? args) #f]
      [(equal? (car args) "--") #f]
      [(is-dir? (car args)) #t]
      [else (loop (cdr args))])))

(define (canopy-restack-startup-picker!)
  (unless *canopy-startup-handled*
    (set! *canopy-startup-handled* #t)
    (when (canopy-launched-with-directory?)
      (with-handler
        (lambda (_) void)
        (begin
          (pop-last-component-by-name! "picker")
          (file_picker))))))

;; #t when the focused buffer is backed by a file, i.e. hx was launched on
;; one; hx . and a bare hx leave a pathless scratch buffer
(define (canopy-focused-buffer-has-file?)
  (with-handler (lambda (_) #f)
    (string? (editor-document->path (editor->doc-id (editor-focus))))))

;;@doc
;; Dock the tree at startup without taking focus; the editor keeps input and
;; canopy-open (e.g. Space-e) focuses the panel. Call from init.scm.
;; #:unless-file #t skips the dock when hx was opened on a file (hx foo.py),
;; still docking for hx . or a bare hx; Space-e opens it on demand either way.
(define (canopy-start! #:unless-file [unless-file #f])
  (enqueue-thread-local-callback
   (lambda ()
     (unless (or *canopy-active*
                 (and unless-file (canopy-focused-buffer-has-file?)))
       (set! *canopy-active* #t)
       (set! *canopy-focused* #f)
       (set! *canopy-query* "")
       (set! *canopy-search-results* '())
       (set! *canopy-typing?* #f)
       (canopy-scan-git-ignored! (canopy-root))
       (canopy-load-state!)
       ;; no explicit reveal: the auto-reveal detector fires when the active
       ;; buffer differs from the last one seen, covering startup and
       ;; buffer-changed-while-hidden. Rebuild the listing (it may have gone
       ;; stale while hidden) and keep the cursor where it was, clamped.
       (canopy-build-tree!)
       (set! *canopy-cursor* (min *canopy-cursor* (max 0 (- (length *canopy-tree*) 1))))
       (canopy-ensure-cursor-visible!)
       (canopy-scan-files!)
       (push-component! (canopy-make-bg-component))
       (canopy-restack-startup-picker!)
       ;; the dock narrows the editor mid-frame; force a clean second frame
       ;; (deferred a tick, like canopy-close!) or the viewport stays blank
       ;; until the next keypress
       (enqueue-thread-local-callback
        (lambda () (helix.redraw)))))))

(define *canopy-mini-min-w* 14)
(define *canopy-mini-max-w* 40)
(define *canopy-mini-min-h* 3)
(define *canopy-mini-max-h* 24)
(define *canopy-mini-gap* 0)
(define *canopy-mini-margin* 1)

(define *canopy-mini-stack* '()) ; list of columns, oldest first and active last

(struct CanopyMiniColumn (path entries cursor))

(define (canopy-mini-list-dir path)
  (define children
    (filter (lambda (p)
              (define name (file-name p))
              (not (or (hashset-contains? *canopy-ignore-set* name)
                       (and (not *canopy-show-hidden*) (canopy-dotfile? name))
                       (and (not *canopy-show-git-ignored*) (canopy-git-ignored? p)))))
            (with-handler (lambda (_) '()) (read-dir path))))
  (map (lambda (p) (cons p (file-name p))) (canopy-sort-entries children)))

(define (canopy-mini-cursor col) (unbox (CanopyMiniColumn-cursor col)))
(define (canopy-mini-set-cursor! col v) (set-box! (CanopyMiniColumn-cursor col) v))

(define (canopy-mini-last lst)
  (if (null? (cdr lst)) (car lst) (canopy-mini-last (cdr lst))))

(define (canopy-mini-drop-last lst)
  (if (null? (cdr lst)) '() (cons (car lst) (canopy-mini-drop-last (cdr lst)))))

(define (canopy-mini-active-column) (canopy-mini-last *canopy-mini-stack*))

(define (canopy-mini-current-entry)
  (define col (canopy-mini-active-column))
  (define entries (CanopyMiniColumn-entries col))
  (and (not (null? entries)) (list-ref entries (canopy-mini-cursor col))))

(define (canopy-mini-move! delta)
  (define col (canopy-mini-active-column))
  (define n (length (CanopyMiniColumn-entries col)))
  (when (> n 0)
    (canopy-mini-set-cursor! col (max 0 (min (- n 1) (+ (canopy-mini-cursor col) delta))))))

(define (canopy-mini-close!)
  (canopy-reset-mouse!)
  (canopy-help-dismiss!)
  (set! *canopy-active* #f)
  (pop-last-component-by-name! "canopy-mini"))

;; entering a directory cascades a new column to the side; a file just opens
(define (canopy-mini-enter!)
  (define entry (canopy-mini-current-entry))
  (cond
    [(not entry) event-result/consume]
    [(is-dir? (car entry))
     (set! *canopy-mini-stack*
           (append *canopy-mini-stack*
                   (list (CanopyMiniColumn (car entry) (canopy-mini-list-dir (car entry)) (box 0)))))
     event-result/consume]
    [(is-file? (car entry))
     (define path (car entry))
     (canopy-mini-close!)
     (enqueue-thread-local-callback (lambda () (helix.open path)))
     event-result/close]
    [else event-result/consume]))

;; steps back to the parent column
(define (canopy-mini-back!)
  (when (> (length *canopy-mini-stack*) 1)
    (set! *canopy-mini-stack* (canopy-mini-drop-last *canopy-mini-stack*))))

;; rebuilds the active column in place after a create/rename/delete,
;; keeping the cursor in bounds
(define (canopy-mini-refresh-active!)
  (define col (canopy-mini-active-column))
  (define new-entries (canopy-mini-list-dir (CanopyMiniColumn-path col)))
  (define new-cursor (max 0 (min (canopy-mini-cursor col) (- (length new-entries) 1))))
  (set! *canopy-mini-stack*
        (append (canopy-mini-drop-last *canopy-mini-stack*)
                (list (CanopyMiniColumn (CanopyMiniColumn-path col) new-entries (box new-cursor))))))

;; refresh after a visibility toggle
(define (canopy-mini-refresh-all!)
  (set! *canopy-mini-stack*
        (map (lambda (col)
               (define new-entries (canopy-mini-list-dir (CanopyMiniColumn-path col)))
               (define new-cursor (max 0 (min (canopy-mini-cursor col) (- (length new-entries) 1))))
               (CanopyMiniColumn (CanopyMiniColumn-path col) new-entries (box new-cursor)))
             *canopy-mini-stack*)))

(set! *canopy-refresh-mini-fn* canopy-mini-refresh-all!)

(define (canopy-mini-index-of lst target)
  (let loop ([l lst] [i 0])
    (cond
      [(null? l) #f]
      [(equal? (car l) target) i]
      [else (loop (cdr l) (+ i 1))])))

;; path segments below root
(define (canopy-mini-relative-components root path)
  (define prefix (string-append root (path-separator)))
  (if (and (>= (string-length path) (string-length prefix))
           (equal? (substring path 0 (string-length prefix)) prefix))
      (split-many (substring path (string-length prefix) (string-length path)) (path-separator))
      '()))

;; cascades a column per ancestor from root down to path
(define (canopy-mini-build-stack-for root path)
  (let loop ([dir root] [comps (canopy-mini-relative-components root path)] [acc '()])
    (define entries (canopy-mini-list-dir dir))
    (cond
      [(null? comps) (reverse (cons (CanopyMiniColumn dir entries (box 0)) acc))]
      [else
       (define idx (canopy-mini-index-of (map cdr entries) (car comps)))
       (define col (CanopyMiniColumn dir entries (box (if idx idx 0))))
       (if (and idx (pair? (cdr comps)))
           (loop (car (list-ref entries idx)) (cdr comps) (cons col acc))
           (reverse (cons col acc)))])))

;; expands ancestors down to whatever file the editor has focused
(define (canopy-mini-reveal-current-file!)
  (define root (canopy-root))
  (define path (editor-document->path (editor->doc-id (editor-focus))))
  (if (string? path)
      (canopy-mini-build-stack-for root path)
      (list (CanopyMiniColumn root (canopy-mini-list-dir root) (box 0)))))

;; flat recursive file list for search, independent of the cascaded columns
(define (canopy-mini-scan-files root)
  (define prefix (string-append root (path-separator)))
  (define acc '())
  (define (walk dir)
    (for-each
     (lambda (p)
       (unless (hashset-contains? *canopy-ignore-set* (file-name p))
         (if (is-dir? p) (walk p) (set! acc (cons p acc)))))
     (with-handler (lambda (_) '()) (read-dir dir))))
  (walk root)
  (sort (map (lambda (p) (substring p (string-length prefix) (string-length p))) acc) string<?))

;; panels grow and shrink with their own content, clamped to safe bounds
(define (canopy-mini-longest-name entries)
  (let loop ([lst entries] [best 0])
    (if (null? lst) best (loop (cdr lst) (max best (string-length (cdr (car lst))))))))

(define *canopy-mini-width-boost* 0)

(define (canopy-mini-col-width entries)
  (min *canopy-mini-max-w* (max *canopy-mini-min-w* (+ (canopy-mini-longest-name entries) 4 *canopy-mini-width-boost*))))

(define (canopy-mini-col-height count max-h)
  (min max-h (max *canopy-mini-min-h* count)))

;; no explicit redraw, consuming the event already re-renders
(define (canopy-mini-wider!)
  (set! *canopy-mini-width-boost* (min 40 (+ *canopy-mini-width-boost* 4))))

(define (canopy-mini-narrower!)
  (set! *canopy-mini-width-boost* (max (- *canopy-mini-min-w*) (- *canopy-mini-width-boost* 4))))

(define (canopy-mini-clamp-window start count height)
  (max 0 (min (max 0 (- count height)) start)))

;; centers the cursor within a column's visible window
(define (canopy-mini-window-start cursor count height)
  (canopy-mini-clamp-window (- cursor (quotient height 2)) count height))

;; a clicked column keeps the window it was clicked against
(define (canopy-mini-pinned-window col cursor count height)
  (if (and *canopy-mini-click-window*
           (equal? col (car *canopy-mini-click-window*)))
      (canopy-mini-clamp-window (cadr *canopy-mini-click-window*) count height)
      (canopy-mini-window-start cursor count height)))

(define *canopy-mini-preview-max-lines* 200)
(define *canopy-mini-preview-min-w* 15)
(define *canopy-mini-preview-max-w* 70)

(define (canopy-mini-preview-lines path max-lines)
  (with-handler
    (lambda (_) (list "(unable to preview)"))
    (let* ([p (open-input-file path)]
           [content (read-port-to-string p)])
      (close-input-port p)
      (canopy-take (split-many content "\n") max-lines))))

(define (canopy-mini-longest-line lines cap)
  (let loop ([lst lines] [best 0])
    (if (null? lst) best (loop (cdr lst) (max best (min cap (string-length (car lst))))))))

(define (canopy-mini-preview)
  (define entry (canopy-mini-current-entry))
  (cond
    [(not entry) (list 'empty #f)]
    [(is-dir? (car entry)) (list 'dir (canopy-mini-list-dir (car entry)))]
    [(is-file? (car entry)) (list 'file (canopy-mini-preview-lines (car entry) *canopy-mini-preview-max-lines*))]
    [else (list 'empty #f)]))

(define (canopy-mini-prompt-create!)
  (define col (canopy-mini-active-column))
  (define base (string-append (CanopyMiniColumn-path col) (path-separator)))
  (enqueue-thread-local-callback
   (lambda ()
     (canopy-show-modal!
      'input
      "New"
      (string-append "New (end with " (path-separator) " for dir): ")
      (canopy-relpath base)
      (lambda (name)
        (define full (string-append (canopy-root) (path-separator) name))
        (with-handler
          (lambda (err) (canopy-error (string-append "create failed: " (error-object-message err))))
          (begin
            (if (ends-with? name (path-separator))
                (canopy-run-mkdir-p! full)
                (begin
                  (canopy-run-mkdir-p! (canopy-parent-path full))
                  (canopy-run-touch! full)
                  (helix.open full)))
            (canopy-info (string-append "created " name))))
        (enqueue-thread-local-callback canopy-mini-refresh-active!))))))

(define (canopy-mini-prompt-rename!)
  (define entry (canopy-mini-current-entry))
  (when entry
    (define path (car entry))
    (define name (file-name path))
    (define dir (trim-end-matches path (string-append (path-separator) name)))
    (enqueue-thread-local-callback
     (lambda ()
       (canopy-show-modal!
        'input
        "Rename"
        "Rename: "
        name
        (lambda (new-name)
          (when (and (not (equal? new-name "")) (not (equal? new-name name)))
            (with-handler
              (lambda (err) (canopy-error (string-append "rename failed: " (error-object-message err))))
              (begin
                (canopy-run-mv! path (string-append dir (path-separator) new-name))
                (canopy-repath-open-buffer! path (string-append dir (path-separator) new-name))
                (canopy-info (string-append "renamed " name " -> " new-name))))
            (enqueue-thread-local-callback canopy-mini-refresh-active!))))))))

(define (canopy-mini-prompt-delete!)
  (define entry (canopy-mini-current-entry))
  (when entry
    (define path (car entry))
    (define name (file-name path))
    (define kind (if (is-dir? path) "directory" "file"))
    (enqueue-thread-local-callback
     (lambda ()
       (canopy-show-modal!
        'confirm
        "Delete"
        (string-append "Delete " kind " '" name "'? (y/N) ")
        ""
        (lambda (confirmed?)
          (when confirmed?
            (with-handler
              (lambda (err) (canopy-error (string-append "delete failed: " (error-object-message err))))
              (begin
                (canopy-delete-recursive! path)
                (canopy-info (string-append "deleted " name))))
            (enqueue-thread-local-callback canopy-mini-refresh-active!))))))))

;; searches the whole workspace and re-cascades the stack to the match
(define (canopy-mini-prompt-search!)
  (define root (canopy-root))
  (enqueue-thread-local-callback
   (lambda ()
     (canopy-show-modal!
      'input
      "Search"
      "Search: "
      ""
      (lambda (query)
        (unless (equal? query "")
          (define matches (fuzzy-match query (canopy-mini-scan-files root)))
          (if (null? matches)
              (canopy-error (string-append "no matches for '" query "'"))
              (set! *canopy-mini-stack*
                    (canopy-mini-build-stack-for root (string-append root (path-separator) (car matches)))))))))))

(struct CanopyMiniState ())

(define (canopy-mini-render-entries frame x y0 w h entries ws cursor active?
                               text-style hl-style dir-style dim-style)
  (if (null? entries)
      (frame-set-string! frame x y0 (canopy-truncate "(empty)" w) dim-style)
      (let iloop ([items (canopy-take (canopy-drop entries ws) h)] [row 0])
        (unless (or (null? items) (>= row h))
          (define e (car items))
          (define idx (+ ws row))
          (define dir? (is-dir? (car e)))
          (define hl? (and active? (= idx cursor)))
          (define icon (if dir? (glyph-dir-icon (cdr e)) (canopy-file-icon (cdr e))))
          (define icon-color (if dir? (glyph-dir-color (cdr e)) (canopy-file-color (cdr e))))
          (define git-status (and (not dir?) (canopy-git-status (car e))))
          (define git-icon (if git-status (glyph-git-icon git-status) " "))
          (define git-color (if git-status (glyph-git-color git-status) #f))
          (define row-style (cond [hl? hl-style] [dir? dir-style] [else text-style]))
          (define name (string-append (cdr e) (if dir? (path-separator) "")))
          (define icon-w (string-length icon))
          (define git-x (+ x icon-w 1))
          (define git-w (if dir? 0 1))
          (define gap (if dir? 0 1))
          (define name-x (+ git-x git-w gap))
          (define avail (max 0 (- w icon-w 1 git-w gap)))
          (define y (+ y0 row))
          (when hl? (frame-set-string! frame x y (make-string w #\space) hl-style))
          (frame-set-string! frame x y icon (glyph-style icon-color #:base row-style))
          (unless dir?
            (frame-set-string! frame git-x y git-icon
                                (if git-color (glyph-style git-color #:base row-style) row-style)))
          (frame-set-string! frame name-x y (canopy-truncate name avail) row-style)
          (iloop (cdr items) (+ row 1))))))

;; file-preview panel in plain text
(define (canopy-mini-render-lines frame x y0 w h lines style)
  (let iloop ([items (canopy-take lines h)] [row 0])
    (unless (or (null? items) (>= row h))
      (frame-set-string! frame x (+ y0 row) (canopy-truncate (car items) w) style)
      (iloop (cdr items) (+ row 1)))))

;; recorded while rendering: which ancestors survived the fit isn't visible to the handler
(define *canopy-mini-hit-panels* '()) ; one area per panel drawn, borders included
(define *canopy-mini-hit-cols* '())   ; (area column window-start) per column
(define *canopy-mini-hit-preview* #f) ; (area entry-count) when the preview lists a directory

;; one box over all of them would swallow clicks beside a short column
(define (canopy-mini-inside-panel? event)
  (let loop ([ps *canopy-mini-hit-panels*])
    (cond
      [(null? ps) #f]
      [(canopy-mouse-in-area? event (car ps)) #t]
      [else (loop (cdr ps))])))

;; (column entry-index window-start), or #f when no column is under the pointer
(define (canopy-mini-hit event)
  (let loop ([cs *canopy-mini-hit-cols*])
    (cond
      [(null? cs) #f]
      [else
       (define rect (list-ref (car cs) 0))
       (define col (list-ref (car cs) 1))
       (define ws (list-ref (car cs) 2))
       (if (canopy-mouse-in-area? event rect)
           (list col (+ ws (- (event-mouse-row event) (area-y rect))) ws)
           (loop (cdr cs)))])))

(define (canopy-mini-in-preview? event)
  (and *canopy-mini-hit-preview*
       (canopy-mouse-in-area? event (car *canopy-mini-hit-preview*))))

;; as above, but a column hit carries the entry, since a panel holds many
(define (canopy-mini-click-target event hit)
  (cond
    [hit (list 'entry (list-ref hit 0) (list-ref hit 1))]
    [(canopy-mini-in-preview? event) 'preview]
    [(canopy-mini-inside-panel? event) 'panel]
    [else 'buffer]))

(define (canopy-mini-click! hit)
  (define col (list-ref hit 0))
  (define entry-idx (list-ref hit 1))
  (define ws (list-ref hit 2))
  (define entries (CanopyMiniColumn-entries col))
  (cond
    [(or (null? entries) (>= entry-idx (length entries))) event-result/consume]
    [else
     (define idx (canopy-mini-index-of *canopy-mini-stack* col))
     (define active? (equal? col (canopy-mini-active-column)))
     (define slot (list idx entry-idx))
     (cond
       ;; second click on the same entry cascades into it or opens it
       [(and active? (equal? slot *canopy-click-slot*))
        ;; cascading rebuilds the stack, so the armed slot stops meaning anything
        (canopy-forget-click!)
        (canopy-mini-enter!)]
       [else
        ;; clicking an ancestor drops the cascade off it, as h repeatedly would
        (when (and idx (not active?))
          (set! *canopy-mini-stack* (canopy-take *canopy-mini-stack* (+ idx 1))))
        (canopy-mini-set-cursor! col entry-idx)
        (canopy-arm-click! slot)
        (set! *canopy-mini-click-window* (list col ws))
        event-result/consume])]))

;; the preview looks just like the column cascading would open, so a click descends
;; and lands on the entry clicked
(define (canopy-mini-preview-click! event)
  (define row (- (event-mouse-row event) (area-y (car *canopy-mini-hit-preview*))))
  (define entry (canopy-mini-current-entry))
  (cond
    ;; a short directory is padded to the minimum height; that padding is inert
    [(or (< row 0) (>= row (cadr *canopy-mini-hit-preview*))) event-result/consume]
    [(not (and entry (is-dir? (car entry)))) event-result/consume]
    [else
     (define result (canopy-mini-enter!))
     (define col (canopy-mini-active-column))
     ;; the directory can have shrunk since it was drawn
     (when (< row (length (CanopyMiniColumn-entries col)))
       (canopy-mini-set-cursor! col row)
       (canopy-arm-click! (list (canopy-mini-index-of *canopy-mini-stack* col) row))
       ;; the preview is drawn from the top, so the cascaded column has to be too
       (set! *canopy-mini-click-window* (list col 0)))
     result]))

(define (canopy-mini-handle-mouse state event)
  (define dir (canopy-mouse-scroll-direction event))
  (define hit (canopy-mini-hit event))
  (cond
    [(canopy-mouse-left-down? event)
     (canopy-press! (canopy-mini-click-target event hit))
     event-result/consume]
    [(canopy-mouse-left-up? event)
     (define target (canopy-mini-click-target event hit))
     (cond
       [(not (equal? target (canopy-take-press!))) event-result/consume]
       [hit (canopy-mini-click! hit)]
       [(equal? target 'preview) (canopy-mini-preview-click! event)]
       [(equal? target 'panel) event-result/consume]
       ;; the columns float over the buffer, so clicking off them matches escape
       [else
        (canopy-mini-close!)
        event-result/close])]
    ;; a column's window follows its cursor, so scrolling an ancestor could only
    ;; move the screen by moving its selection, dropping the cascade off it
    [(and dir (or (not hit) (equal? (list-ref hit 0) (canopy-mini-active-column))))
     (if (canopy-mini-inside-panel? event)
         ;; a short column doesn't scroll under the pointer, so the arm goes with it
         (begin
           (canopy-forget-click!)
           (canopy-debounce-scroll!
            (lambda ()
              (canopy-mini-move! (if (equal? dir 'up)
                                     (- *canopy-scroll-amount*)
                                     *canopy-scroll-amount*))))
           event-result/consume)
         event-result/ignore)]
    [else event-result/consume]))

(define (canopy-mini-render state rect frame)
  (define sw (area-width rect))
  (define sh (area-height rect))
  (define max-h (min *canopy-mini-max-h* (max *canopy-mini-min-h* (- sh 4))))

  (define bg-style (theme-scope-ref "ui.background"))
  (define text-style (theme-scope-ref "ui.text"))
  (define hl-style (theme-scope-ref "ui.menu.selected"))
  (define dir-style (theme-scope-ref "ui.text.info"))
  (define dim-style (style-with-dim (theme-scope-ref "ui.text")))
  ;; border matches bg so it blends in instead of clashing across themes
  (define border-style bg-style)

  (define active-col (canopy-mini-active-column))

  (define col-specs
    (map (lambda (col)
           (define entries (CanopyMiniColumn-entries col))
           (list 'col col (canopy-mini-col-width entries) (canopy-mini-col-height (length entries) max-h)))
         *canopy-mini-stack*))

  (define preview (canopy-mini-preview))
  (define preview-kind (car preview))
  (define preview-data (cadr preview))
  (define preview-spec
    (cond
      [(equal? preview-kind 'dir)
       (list 'preview-dir preview-data
             (canopy-mini-col-width preview-data) (canopy-mini-col-height (length preview-data) max-h))]
      [(equal? preview-kind 'file)
       (list 'preview-file preview-data
             (min *canopy-mini-preview-max-w*
                  (max *canopy-mini-preview-min-w*
                       (+ (canopy-mini-longest-line preview-data *canopy-mini-preview-max-w*) 4 *canopy-mini-width-boost*)))
             (canopy-mini-col-height (length preview-data) max-h))]
      [else (list 'preview-empty #f *canopy-mini-min-w* *canopy-mini-min-h*)]))

  (define all-specs (append col-specs (list preview-spec)))

  (define (total-width specs)
    (+ (apply + (map (lambda (s) (+ (list-ref s 2) 2)) specs))
       (* *canopy-mini-gap* (max 0 (- (length specs) 1)))))

  ;; drop the oldest ancestor columns first if the stack is wider than the screen
  (define (fit specs)
    (if (or (<= (total-width specs) (- sw 2)) (<= (length specs) 2))
        specs
        (fit (cdr specs))))
  (define visible (fit all-specs))

  ;; anchor at a top corner
  (define x0 (if (equal? *canopy-side* 'right)
                 (max 0 (- sw (total-width visible) *canopy-mini-margin*))
                 *canopy-mini-margin*))
  (define y0 *canopy-mini-margin*)

  (set! *canopy-mini-hit-cols* '())
  (set! *canopy-mini-hit-panels* '())
  (set! *canopy-mini-hit-preview* #f)

  (let loop ([lst visible] [x x0])
    (unless (null? lst)
      (define spec (car lst))
      (define kind (list-ref spec 0))
      (define w (list-ref spec 2))
      (define h (list-ref spec 3))
      (define pw (+ w 2))
      (define ph (+ h 2))
      (define panel-area (area x y0 pw ph))
      (define cx (+ x 1))
      (define cy (+ y0 1))

      (buffer/clear-with frame panel-area bg-style)
      (block/render frame panel-area (make-block bg-style border-style "all" "rounded"))
      (set! *canopy-mini-hit-panels* (cons panel-area *canopy-mini-hit-panels*))

      (cond
        [(equal? kind 'col)
         (define col (list-ref spec 1))
         (define entries (CanopyMiniColumn-entries col))
         (define cursor (canopy-mini-cursor col))
         (define active? (equal? col active-col))
         (define ws (canopy-mini-pinned-window col cursor (length entries) h))
         (set! *canopy-mini-hit-cols* (cons (list (area cx cy w h) col ws) *canopy-mini-hit-cols*))
         (canopy-mini-render-entries frame cx cy w h entries ws cursor active?
                                text-style hl-style dir-style dim-style)]
        [(equal? kind 'preview-dir)
         (set! *canopy-mini-hit-preview* (list (area cx cy w h) (length (list-ref spec 1))))
         (canopy-mini-render-entries frame cx cy w h (list-ref spec 1) 0 -1 #f
                                text-style hl-style dir-style dim-style)]
        [(equal? kind 'preview-file)
         (canopy-mini-render-lines frame cx cy w h (list-ref spec 1) dim-style)]
        [else
         (frame-set-string! frame cx cy (canopy-truncate "(empty)" w) dim-style)])

      (loop (cdr lst) (+ x pw *canopy-mini-gap*)))))

(define (canopy-mini-command-action! action)
  (cond
    [(equal? action 'down) (canopy-mini-move! 1) event-result/consume]
    [(equal? action 'up) (canopy-mini-move! -1) event-result/consume]
    [(equal? action 'enter) (canopy-mini-enter!)]
    [(equal? action 'back) (canopy-mini-back!) event-result/consume]
    [(equal? action 'quit) (canopy-mini-close!) event-result/close]
    [(equal? action 'create) (canopy-mini-prompt-create!) event-result/consume]
    [(equal? action 'rename) (canopy-mini-prompt-rename!) event-result/consume]
    [(equal? action 'delete) (canopy-mini-prompt-delete!) event-result/consume]
    [(equal? action 'refresh) (canopy-mini-refresh-active!) event-result/consume]
    [(equal? action 'search) (canopy-mini-prompt-search!) event-result/consume]
    [(equal? action 'toggle-hidden) (canopy-toggle-hidden!) event-result/consume]
    [(equal? action 'toggle-git-ignored) (canopy-toggle-git-ignored!) event-result/consume]
    [(equal? action 'wider) (canopy-mini-wider!) event-result/consume]
    [(equal? action 'narrower) (canopy-mini-narrower!) event-result/consume]
    [(equal? action 'menu) (canopy-whichkey-open! 'mini canopy-mini-command-action!) event-result/consume]
    [else event-result/consume]))

(define (canopy-mini-handle-keys state event)
  (define ch (key-event-char event))
  (cond
    [(key-event-down? event) (canopy-mini-move! 1) event-result/consume]
    [(key-event-up? event) (canopy-mini-move! -1) event-result/consume]
    [(key-event-right? event) (canopy-mini-enter!)]
    [(key-event-enter? event) (canopy-mini-enter!)]
    [(key-event-left? event) (canopy-mini-back!) event-result/consume]
    [(key-event-escape? event) (canopy-mini-close!) event-result/close]

    [(and (char? ch) (equal? ch #\=)) (canopy-mini-wider!) event-result/consume] ; legacy alias

    [(char? ch)
     (define action (canopy-action-for-char ch))
     (if action (canopy-mini-command-action! action) event-result/consume)]

    [else event-result/consume]))

(define (canopy-mini-handle-event state event)
  (cond
    ;; do not register keys when doing new/rename
    [*canopy-modal-open?* event-result/ignore]
    [*canopy-help-open?* event-result/ignore]
    [(mouse-event? event) (canopy-mini-handle-mouse state event)]
    [else
     ;; any keypress can move the cursor, so an armed entry stops meaning anything
     (canopy-reset-mouse!)
     (canopy-mini-handle-keys state event)]))

(define (canopy-mini-make-component)
  (new-component! "canopy-mini" (CanopyMiniState) canopy-mini-render (hash "handle_event" canopy-mini-handle-event)))

(define (canopy-mini-open!)
  (cond
    [(not *canopy-active*)
     (canopy-scan-git-ignored! (canopy-root))
     (set! *canopy-mini-stack* (canopy-mini-reveal-current-file!))
     (set! *canopy-active* #t)
     (push-component! (canopy-mini-make-component))]
    [else (canopy-mini-close!)]))

;;@doc
;; Open the file tree
(define (canopy-open)
  (if (equal? *canopy-style* 'mini)
      (canopy-mini-open!)
      (canopy-snacks-open!)))

;;@doc
;; Close the file tree
(define (canopy-close)
  (when *canopy-active*
    (if (equal? *canopy-style* 'mini)
        (canopy-mini-close!)
        (canopy-close!))))

;;@doc
;; Focus the docked tree, opening it first if it is not visible. A no-op when
;; the tree already holds focus (unlike canopy-open, which would bounce back).
(define (canopy-focus)
  (cond
    [(equal? *canopy-style* 'mini) (canopy-mini-open!)]
    [(and *canopy-active* *canopy-focused*) void]
    [else (canopy-snacks-open!)]))

;;@doc
;; Toggle the docked tree's visibility without moving focus into it.
(define (canopy-toggle)
  (if *canopy-active*
      (canopy-close)
      (canopy-start!)))
