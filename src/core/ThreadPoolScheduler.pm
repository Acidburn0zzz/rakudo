# The ThreadPoolScheduler is a straightforward scheduler that maintains a
# pool of threads and schedules work items in the order they are added
# using them.

my class ThreadPoolScheduler does Scheduler {
    # A concurrent work queue that blocks any worker threads that poll it
    # when empty until some work arrives.
    my class Queue is repr('ConcBlockingQueue') { }
    has $!queue;
    
    # Semaphore to ensure we don't start more than the maximum number of
    # threads allowed.
    has $!thread_start_semaphore;
    
    # Number of outstanding work items, used for rough management of the
    # pool size. Also a lock to protect updates to it. (TODO: use atomic
    # operations for this in the future.)
    has int $!loads;
    has $!loads_lock;
    
    # Initial and maximum threads.
    has $!initial_threads;
    has $!max_threads;
    
    # Have we started any threads yet?
    has int $!started_any;
    
    # Timer for interval-scheduled things.
    has $!timer;

    # Adds a new thread to the pool, respecting the maximum.
    method !maybe_new_thread() {
        if $!thread_start_semaphore.try_acquire() {
            $!started_any = 1;
            Thread.start(:app_lifetime, {
                loop {
                    my Mu $task := nqp::shift($!queue);
                    try {
                        $task();
                        CATCH {
                            default {
                                self.handle_uncaught($_)
                            }
                        }
                    }
                    $!loads_lock.protect: { $!loads = $!loads - 1 };
                }
            });
        }
    }
    
    submethod BUILD(:$!initial_threads = 0, :$!max_threads = 16) {
        die "Initial thread pool threads must be less than or equal to maximum threads"
            if $!initial_threads > $!max_threads;
    }
    
    method cue(&code, :$at, :$in, :$every, :$times = 1, :&catch ) {
        die "Cannot specify :at and :in at the same time"
          if $at.defined and $in.defined;
        die "Cannot specify :every and :times at the same time"
          if $every.defined and $times > 1;
        my $delay = $at ?? $at - now !! $in // 0;
        self!initialize unless $!started_any;

        # need repeating
        if $every {
#?if jvm
            $!timer.'method/scheduleAtFixedRate/(Ljava/util/TimerTask;JJ)V'(
              nqp::jvmbootinterop().proxy(
                'java.util.TimerTask',
                nqp::hash( 'run', &catch
                  ?? -> { code(); CATCH { default { catch($_) } } }
                  !! -> { code() }
                )
              ),
              ($delay * 1000).Int,
              ($every * 1000).Int);
#?endif
#?if moar
            die ":at/:in/:every/:times NYI on MoarVM backend";
#?endif
        }

        # only after waiting a bit or more than once
        elsif $delay or $times > 1 {
#?if jvm
            my $todo :=nqp::hash( 'run', &catch
              ?? -> { code(); CATCH { default { catch($_) } } }
              !! -> { code() } );
            for 1 .. $times {
                $!timer.'method/schedule/(Ljava/util/TimerTask;J)V'(
                  nqp::jvmbootinterop().proxy('java.util.TimerTask', $todo),
                  ($delay * 1000).Int);
                $delay = 0;
            }
#?endif
#?if moar
            die ":at/:in/:every/:times NYI on MoarVM backend";
#?endif
        }

        # just cue the code
        else {
            my &run := &catch 
               ?? -> { code(); CATCH { default { catch($_) } } }
               !! &code;
            my $loads = $!loads_lock.protect: { $!loads = $!loads + 1 };
            self!maybe_new_thread()
                if !$!started_any || $loads > 1;
            nqp::push($!queue, &run);
        }
    }

    method loads() {
        return 0 unless $!started_any;
        $!loads
    }

    method !initialize() {
        $!queue                  := nqp::create(Queue);
        $!thread_start_semaphore := Semaphore.new($!max_threads.Int);
        $!loads_lock             := nqp::create(Lock);
#?if jvm
        my $interop              := nqp::jvmbootinterop();
        my \Timer                := $interop.typeForName('java.util.Timer');
        $!timer                  := Timer.'constructor/new/(Z)V'(True);
#?endif
        self!maybe_new_thread() for 1..$!initial_threads;
    }
}

# This thread pool scheduler will be the default one.
$PROCESS::SCHEDULER = ThreadPoolScheduler.new();
