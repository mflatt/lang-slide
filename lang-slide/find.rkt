#lang racket
(require racket/system
         racket/draw
         racket/runtime-path
         "orig-colors.rkt")

(define root-of-plt-git
  (simplify-path 
   (build-path (collection-file-path "base.rkt" "racket")
               'up 'up 'up 'up)))

(define (get-language i)
  (and (or (regexp-match #rx"scrbl$" (path->string i))
           (regexp-match #rx"[.]rkt$" (path->string i))
           (regexp-match #rx"[.]ss$" (path->string i))
           (regexp-match #rx"[.]scm$" (path->string i)))
       (call-with-input-file i
         (λ (port)
           (simplify-language
            (and (not (skip-file? i))
                 (parameterize ([read-accept-reader #t])
                   (with-handlers ((exn:fail? (λ (x) (printf "exn when reading ~s\n" i) #f #;(raise x))))
                     (let loop ()
                       (let ([line (read-line (peeking-input-port port))])
                         (cond
                           [(eof-object? line)
                            (error 'get-language "got to eof without finding a language")]
                           [(regexp-match #rx"[(]" line)
                            (cond
                              [(regexp-match #rx"module [^ ]* +(.*)$" line)
                               =>
                               (λ (m)
                                 (let ([obj (read (open-input-string (list-ref m 1)))])
                                   (if (string? obj)
                                       (format "s-exp ~a" obj)
                                       (format "~a" obj))))]
                              [else
                               (match (read port)
                                 [`(module ,modname ,lang ,stuff ...)
                                  (if (string? lang)
                                      (format "s-exp ~a" lang)
                                      (format "~a" lang))]
                                 [else
                                  
                                  #f ;; here we just assume there is no language specified
                                  #;(error 'get-language "found a paren, but not a module expression in ~s" i)])])]
                           [(regexp-match #rx"#reader ?scribble/reader" line)
                            (read-line port)
                            (loop)]
                           [(regexp-match #rx"#reader" line)
                            (parse-reader-line port)]
                           [(regexp-match #rx"#lang (.*)$" line)
                            =>
                            (λ (m) (list-ref m 1))]
                           [(regexp-match #rx"#!r6rs$" line) "r6rs"]
                           [else
                            (read-line port)
                            (loop)])))))))))))

(define (simplify-language lang)
  (and lang
       (let ([lang 
              (regexp-replace
               #rx" +$"
               (regexp-replace* #rx"\"" 
                                (regexp-replace* #rx"s-exp " lang "") 
                                "")
               "")])
         (cond
           [(regexp-match #rx"^scheme" lang)
            (simplify-language (string-append "racket" (substring lang 6)))]
           [(regexp-match #rx"#%kernel" lang)
            "#%kernel"]
           [(regexp-match #rx"lib infotab.ss setup" lang)
            "setup/infotab"]
           [(regexp-match #rx"slideshow" lang)
            "slideshow"]
           [(regexp-match #rx"typed/scheme$" lang)
            "typed/racket"]
           [(regexp-match #rx"typed-scheme$" lang)
            "typed/racket"]
           [(regexp-match #rx"typed/racket #:with-refinements" lang)
            "typed/racket"]
           [(regexp-match #rx"typed/racket/base #:with-refinements" lang)
            "typed/racket/base"]
           [(regexp-match #rx"racket/unit/lang" lang)
            "racket/unit"]
           [(regexp-match #rx"hyper-literate racket" lang)
            "racket"]
           [(regexp-match #rx"hyper-literate typed/racket" lang)
            "typed/racket"]
           [(regexp-match #rx"typed-racket/base-env/extra-env-lang" lang)
            "typed-racket/extra-env-lang"]
           [(regexp-match #rx"srfi/provider" lang)
            "srfi/provider"]
           [(regexp-match #rx"htdp/bsl/reader" lang)
            "htdp/bsl"]
           [(regexp-match #rx"htdp-beginner.ss" lang)
            "htdp/bsl"]
           [(regexp-match #rx"htdp-intermediate.ss" lang)
            "htdp/isl"]
           [(regexp-match #rx"htdp-intermediate-lambda.ss" lang)
            "htdp/isl+"]
           [(regexp-match #rx"htdp-advanced.ss" lang)
            "htdp/asl"]
           [else lang]))))
       

(define (skip-file? path)
  (let ([str (path->string path)])
    (or (regexp-match #rx"collects/games/loa/main.ss" str)
        (regexp-match #rx"collects/tests" str)
        (regexp-match #rx"collects/scribblings/guide/contracts-examples" str)
        (regexp-match #rx"collects/htdp/tests/matrix-" str)
        (regexp-match #rx"collects/scribblings/guide/read.scrbl" str))))

(define (parse-reader-line port)
  (let ([line (read-line port)])
    (cond
      [(regexp-match #rx"htdp-beginner-reader.ss" line)
       "htdp/bsl"]
      [else
       (error 'parse-reader-line "unknown line ~s" line)])))
             

(define ht (make-hash))
(for ((i (in-directory root-of-plt-git)))
  (let ([lang (get-language i)])
    (when lang
      (hash-set! ht lang (cons i (hash-ref ht lang '()))))))
(let ([one-offs '()])
  (hash-for-each
   ht
   (λ (k v) (when (= 1 (length v))
              (hash-remove! ht k)
              (set! one-offs (cons (car v) one-offs)))))
  (hash-set! ht "one off language" one-offs))
   
(sort (hash-map ht (λ (x y) (list x (length y)))) string<=? #:key car)

(define existing-edges (make-hash))
(define existing-interior-nodes (make-hash))
(define directory->languages (make-hash))

(define depth-table (make-hash))

(define path->rank
  (let ([rank-table (make-hash)])
    (λ (path)
      (hash-ref rank-table path
                (λ ()
                  (let ([next (hash-count rank-table)])
                    (hash-set! rank-table path (format "rank~a" next))
                    (format "rank~a" next)))))))

(define (file-to-dot filename language)
  (let ([path (find-relative-path root-of-plt-git filename)])
    (let loop ([eles (explode-path path)]
               [parent (build-path 'same)]
               [depth 0])
      (let* ([child (build-path parent (car eles))]
             [key (cons parent child)])
        
        (cond
          [(null? (cdr eles))
           (unless (member language (hash-ref directory->languages parent '()))
             (hash-set! directory->languages parent (cons language (hash-ref directory->languages parent '())))
             (unless (hash-ref existing-edges key #f)
               (hash-set! existing-edges key #t)
               (printf "  \"~a\" -> \"~a\" [color=gray,arrowhead=none,arrowtail=none];\n" parent child))
             (hash-set! depth-table depth (+ 1 (hash-ref depth-table depth 0)))
             (let ([rank (path->rank parent)])
               (printf "  \"~a\" [label=\"\",shape=circle,fillcolor=\"~a\",color=\"~a\",style=filled] ;\n" 
                       (path->string child)
                       (language->color filename language)
                       (language->color filename language))))]
          [else
           (unless (hash-ref existing-edges key #f)
             (hash-set! existing-edges key #t)
             (printf "  \"~a\" -> \"~a\" [color=gray,arrowhead=none,arrowtail=none];\n" parent child))
           (unless (hash-ref existing-interior-nodes parent #f)
             (hash-set! existing-interior-nodes parent #t)
             (printf "  \"~a\" [shape=point,color=gray];\n" parent))
           (unless (hash-ref existing-interior-nodes child #f)
             (hash-set! existing-interior-nodes child #t)
             (printf "  \"~a\" [shape=point,color=gray];\n" child))
           (loop (cdr eles) child (+ depth 1))])))))

(define colors (make-hash))  

(define (language->color file lang)
  (hash-ref colors lang 
            (λ ()
              (cond
                [(regexp-match #rx"web" lang)
                 (next-color lang 'purple)]
                [(or (regexp-match #rx"lazy" lang))
                 (next-color lang 'gray)]
                [(or (regexp-match #rx"typed" lang)
                     (regexp-match #rx"env-lang.rkt" lang)
                     (regexp-match #rx"type-exp" lang))
                 (next-color lang 'orange)]
                [(or (regexp-match #rx"at-exp" lang)
                     (regexp-match #rx"pollen" lang)
                     (regexp-match #rx"scribble" lang))
                 (next-color lang 'red)]
                [(or (regexp-match #rx"scheme" lang)
                     (regexp-match #rx"racket" lang)
                     (regexp-match #rx"slideshow" lang)
                     (regexp-match #rx"#%kernel" lang)
                     (regexp-match #rx"pre-base.rkt" lang))
                 (next-color lang 'blue)]
                [(or (regexp-match #rx"srfi" lang)
                     (regexp-match #rx"r6rs" lang)
                     (regexp-match #rx"r5rs" lang))
                 (next-color lang 'pink)]
                [(or (regexp-match #rx"wrapper" lang)
                     (regexp-match #rx"wrap.rkt" lang)
                     (regexp-match #rx"reprovide" lang)
                     (regexp-match #rx"module-reader" lang))
                 (next-color lang 'brown)]
                [(or (regexp-match #rx"setup" lang)
                     (regexp-match #rx"info" lang))
                 (next-color lang 'yellow)]
                [(or (regexp-match #rx"htdp" lang)
                     (regexp-match #rx"DMdA" lang)
                     (regexp-match #rx"eopl" lang)
                     (regexp-match #rx"plai" lang))
                 (next-color lang 'green)]
                [(or (regexp-match #rx"datalog" lang)
                     (regexp-match #rx"racklog" lang)
                     (regexp-match #rx"frtime" lang)
                     (regexp-match #rx"swindle" lang)
                     (regexp-match #rx"honu" lang)
                     (regexp-match #rx"hackett" lang))
                 (next-color lang 'cyan)]
                [else
                 (fprintf (current-error-port) "unknown language ~s ~s\n" lang (length (hash-ref ht lang)))
                 (new-color lang 0 0 0)]))))

(define (new-color lang r g b)
  (define new-color (string-append 
                     "#"
                     (to-hex r)
                     (to-hex g)
                     (to-hex b)))
  (hash-set! colors lang new-color)
  new-color)

(define colors-table (hash-copy orig-colors))

(define (next-color lang key)
  (let ([lst (hash-ref colors-table key)])
    (cond
      [(null? lst) 
       (eprintf "ran out of ~a for ~a\n" key lang)
       (hash-set! colors-table key (hash-ref orig-colors key))
       (next-color lang key)]
      [else
       (hash-set! colors-table key (cdr lst))
       (cond
         [(list? (car lst))
          (apply new-color lang (car lst))]
         [else 
          (let ([color (send the-color-database find-color (car lst))])
            (new-color lang 
                       (send color red)
                       (send color green)
                       (send color blue)))])])))

(define (to-hex n)
  (cond
    [(<= n 15) (format "0~a" (number->string n 16))]
    [else (number->string n 16)]))

(define (to-dot)
  (printf "digraph {\n")
  (hash-for-each
   ht
   (λ (lang files)
     (for-each
      (λ (file) (file-to-dot file lang))
      files)))
  (printf "}\n"))

(call-with-output-file "lang.dot"
  (λ (port)
    (parameterize ([current-output-port port])
      (to-dot)))
  #:exists 'truncate)

(define-runtime-path lang-colors.rktd "lang-colors.rktd")
(call-with-output-file lang-colors.rktd
  (λ (port)
    (pretty-write
     (sort (hash-map colors list)
           string<=?
           #:key car)
     port))
  #:exists 'truncate)

(printf "calling twopi\n")
(void
 (parameterize ([current-input-port (open-input-string "")])
   (system (format "~a -Tplain lang.dot > lang.plain"
                   (if (file-exists? "/usr/local/bin/twopi")
                       "/usr/local/bin/twopi"
                       "/usr/bin/twopi")))))
