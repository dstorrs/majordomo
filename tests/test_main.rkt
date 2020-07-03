#lang racket

(require handy/test-more
         "../main.rkt"
         )

(test-suite
 "basics"

 (define jeeves (start-majordomo))
 (is-type jeeves majordomo? "(start-majordomo) returns a majordomo struct")
 (lives (thunk (stop-majordomo jeeves)) "(stop-majordomo jeeves) works")
 )
