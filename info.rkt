#lang info
(define collection "majordomo")
(define deps '("base" "struct-plus-plus"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define scribblings '(("scribblings/majordomo.scrbl" ())))
(define pkg-desc "Managed job queue with stateful retry")
(define version "0.0")
(define pkg-authors '("David K. Storrs"))

(define test-omit-paths '("test_main.rkt"))

