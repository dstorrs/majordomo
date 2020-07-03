#lang scribble/manual
@require[@for-label[majordomo
                    racket/base]]

@title{majordomo}
@author{David K. Storrs}

@defmodule[majordomo]

@section{Synopsis}

Majordomo is a managed task manager.  Specific features:

- Restarts jobs if they fail or stall
- Enables restarted jobs to pick up from where they left off
- Enables communication between the worker thread and the thread submitting the job
