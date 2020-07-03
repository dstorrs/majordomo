#lang racket

(require handy/test-more
         handy/hash
         handy/utils
         racket/async-channel
         "../main.rkt"
         "../private/task.rkt")

(test-suite
 "start, stop, basic accessors"

 (define  jeeves (start-majordomo))
 (is-type jeeves majordomo? "(start-majordomo) returns a majordomo struct")
 (lives   (thunk (stop-majordomo jeeves)) "(stop-majordomo jeeves) works"))


(test-suite
 "start-task"

 (define  jeeves (start-majordomo))

 (is-type (start-task jeeves (lambda (the-task) 'ok))
          task?
          "start-task returns a task struct")


 (define the-task
   (start-task jeeves
                (lambda (the-task)
                  ; do a long-running task, e.g. torrenting bits of a file
                  (define to-manager (task.manager-ch the-task))
                  (define data (task.data the-task))
                  (define final-data
                    (for/fold ([data data])
                              ([i (in-range 10)])
                      ; tell the manager that we are working on chunk i
                      (async-channel-put to-manager (hash-meld data (hash i 'wip)))
                      (sleep (random))   ; simulates the download

                      ; tell the manager that we got it
                      (define next (hash-meld data (hash i #t)))
                      (async-channel-put to-manager next)
                      next))
                  (define result (set-task-data (set-task-status the-task 'succeeded)
                                                final-data))
                  (async-channel-put to-manager result))))

 (like (symbol->string (task.id the-task)) #px"^task-" "task-id looks as expected")

 (define result (async-channel-get (task.customer-ch the-task)))
 (is-type result task? "got a task")
 (is (task.status result)
     'succeeded
     "task completed successfully")

 (is (task.data result)
     (for/hash ([i 10]) (values i #t))
     "final state was correct"))
