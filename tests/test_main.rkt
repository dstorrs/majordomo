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
 (let ()
   (define-values (the-task customer-ch)
     (start-task jeeves
                 (lambda (the-task) (tell-manager the-task
                                                  (set-task-status the-task 'succeeded)))))
   (is-type the-task
            task?
            "start-task returns a task struct"))

 (let ()
   (define-values (the-task customer-ch)
     (start-task jeeves
                 (lambda (the-task)
                   ; do a long-running task, e.g. torrenting bits of a file
                   (define data (task.data the-task))
                   (define final-data
                     (for/fold ([data data])
                               ([i (in-range 10)])
                       ; tell the manager that we are working on chunk i
                       (tell-manager the-task (hash-meld data (hash i 'wip)))
                       (sleep 0.1) ; simulates the download

                       ; tell the manager that we got it
                       (define next (hash-meld data (hash i #t)))
                       (tell-manager the-task next)
                       next))
                   (define result (set-task-data (set-task-status the-task 'succeeded)
                                                 final-data))
                   (tell-manager the-task result))))

   (like (symbol->string (task.id the-task)) #px"^task-" "task-id looks as expected")

   (define result (async-channel-get (task.customer-ch the-task)))
   (is-type result task? "got a task")
   (is (task.status result)
       'succeeded
       "task completed successfully")

   (is (task.data result)
       (for/hash ([i 10]) (values i #t))
       "final state was correct")))

(test-suite
 "limited number of retries"

 (define jeeves (start-majordomo))

 (is (max-restarts) 5 "got expected max number of retries")

 (define-values (the-task customer-ch)
   (start-task jeeves (lambda (the-task) #f)))

 (define result (let loop ()
                  (define res (async-channel-get customer-ch))
                  (if (task? res) res (loop))))
 (ok (match result
       [(struct* task ([num-restarts 6] [status 'failed])) #t]
       [else #f])
     "a task only gets 5 retries and then it is marked failed"))

(test-suite
 "timeouts (might take up to 5 seconds)"

 (is (task-timeout) 5 "default max timeout is 5 seconds")

 (define jeeves (start-majordomo))
 (parameterize ([task-timeout 0.1])
   (define result (sync/timeout 5000
                      (thread
                       (thunk
                        (define-values (the-task customer-ch)
                          (start-task jeeves (lambda (the-task) (sync never-evt))))

                        (is-type (async-channel-get customer-ch)
                                 task-msg?
                                 "The manager is notified when a timeout happens")
                        (ok (let loop ()
                              (match (async-channel-get customer-ch)
                                [(struct* task ([num-restarts 6] [status 'failed])) #t]
                                [(? task-msg?) (loop)]
                                [else #f]))
                            "a task that times out too many times is marked failed")))))
   (inc-test-num! 2) ; account for the tests that happened in the other thread
   (ok (thread? result) "timeout tests finished in a reasonable time period")))
