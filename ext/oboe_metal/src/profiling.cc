// Copyright (c) 2020 SolarWinds, LLC.
// All rights reserved.

#include "profiling.h"
#include "logging.h"
#include "frames.h"


static atomic_long running;

// need to initialize here, hangs if it is done inside the signal handler
// these are reused for every snapshot
static struct timeval timestamp;
static VALUE frames_buffer[BUF_SIZE];
static int lines_buffer[BUF_SIZE];
// static vector<FrameData> new_frames;

long interval = 10;  // in milliseconds, initializing in case Ruby forgets to

typedef struct prof_data {
    bool running_p = false;
    oboe_metadata_t *md;
    string prof_op_id;
    pid_t tid;

    struct timeval prev_timestamp;
    VALUE prev_frames_buffer[BUF_SIZE];
    int prev_num = 0;
    long omitted[BUF_SIZE];
    int omitted_num = 0;
} prof_data_t;

unordered_map<pid_t, prof_data_t> prof_data_map;
thread_local unordered_map<VALUE, FrameData> cached_frames;

// TODO maybe use std::async for some stuff that doesn't read the frame info from Ruby
void Profiling::profiler_record_frames(void *data) {

    pid_t tid = AO_GETTID;

    gettimeofday(&timestamp, NULL);
    long ts = (long)timestamp.tv_sec * 1000000 + (long)timestamp.tv_usec;

    // check if this thread is being profiled
    if (prof_data_map[tid].running_p) {
        // exectues in the same thread as rb_postponed_job was called from
        // get the frames
        // won't overrun frames buffer, because size is set in arg 2
        int num = rb_profile_frames(0, sizeof(frames_buffer) / sizeof(VALUE), frames_buffer, lines_buffer);

        // std::async(std::launch::async, Profiling::process_snapshot, frames_buffer, num, tid, ts);
        Profiling::process_snapshot(frames_buffer, num, tid, ts);
    }

    if (getenv("AO_OTHERTHREADS")) {
        // add this timestamp as omitted to other running threads that are profiled
        for (pair<const pid_t, prof_data_t> &ele : prof_data_map) {
            if (ele.second.running_p && ele.first != tid) {
                // ele.second.omitted[ele.second.omitted_num] = ts;
                // ele.second.omitted_num++;
                frames_buffer[0] = PR_OTHER_THREAD;
                Frames::print_raw_frame_info(frames_buffer[0]);
                Profiling::process_snapshot(frames_buffer, 1, ele.first, ts);
            }
        }
    }
}

void Profiling::send_omitted(pid_t tid, long ts) {
    static vector<FrameData> empty;
    Logging::log_profile_snapshot(prof_data_map[tid].md,
                                  prof_data_map[tid].prof_op_id,
                                  ts,                              // timestamp
                                  empty,                           // <vector> new frames
                                  0,                               // number of exited frames
                                  prof_data_map[tid].prev_num,     // total number of frames
                                  prof_data_map[tid].omitted,      // array of timestamps of omitted snapshots
                                  prof_data_map[tid].omitted_num,  // number of omitted snapshots
                                  tid);                            // thread id

    prof_data_map[tid].omitted_num = 0;
}

void Profiling::process_snapshot(VALUE *frames_buffer, int num, pid_t tid, long ts) {
    int num_new = 0;
    int num_exited = 0;
    // TODO is this going to blow up, because it allocates memory?
    vector<FrameData> new_frames;
    num = Frames::remove_garbage(frames_buffer, num);

    // find the number of matching frames from the top
    int num_match = Frames::num_matching(frames_buffer,
                                      num,
                                      prof_data_map[tid].prev_frames_buffer,
                                      prof_data_map[tid].prev_num);
    num_new = num - num_match;

    num_exited = prof_data_map[tid].prev_num - num_match;
    
    // cout << "Numbers: num: " << num << " num_match " << num_match << " num_new " 
    //      << num_new << " num_exited " << num_exited << endl;

    if (num_new == 0 && num_exited == 0) {
        prof_data_map[tid].omitted[prof_data_map[tid].omitted_num] = ts;
        prof_data_map[tid].omitted_num++;
        prof_data_map[tid].prev_timestamp = timestamp;

        // the omitted buffer can fill up if the interval is small
        // and the stack doesn't change
        // We need to send a profiling event with the timestamps when it is full
        if (prof_data_map[tid].omitted_num >= BUF_SIZE) {
            Profiling::send_omitted(tid, ts);
        }
        return;
    }

    Frames::extract_frame_info(frames_buffer, num_new, new_frames);

    // cout << tid
    //      << ": bucket_count = " << cached_frames.bucket_count()
    //      << ", size = " << cached_frames.size()
    //      << ", load_factor = " << cached_frames.load_factor()
    //      << ", max_load_factor = " << cached_frames.max_load_factor() << endl;

    Logging::log_profile_snapshot(prof_data_map[tid].md,
                                  prof_data_map[tid].prof_op_id,
                                  ts,                              // timestamp
                                  new_frames,                      // <vector> new frames
                                                                   //   num_new,                   // number of new frames
                                  num_exited,                      // number of exited frames
                                  num,                             // total number of frames
                                  prof_data_map[tid].omitted,      // array of timestamps of omitted snapshots
                                  prof_data_map[tid].omitted_num,  // number of omitted snapshots
                                  tid);                            // thread id

    prof_data_map[tid].omitted_num = 0;
    prof_data_map[tid].prev_timestamp = timestamp;
    prof_data_map[tid].prev_num = num;
    for (int i = 0; i < num; ++i)
        prof_data_map[tid].prev_frames_buffer[i] = frames_buffer[i];
}

void Profiling::profiler_job_handler(void *data) {
    static std::atomic_int in_job_handler;

    pid_t tid = AO_GETTID;
    gettimeofday(&timestamp, NULL); 
    long ts = ((long)timestamp.tv_sec*1000 + (long)timestamp.tv_usec/1000)%10000;
    // std::cout << "Time: " << ts << ",  tid " << tid << ",  running? " << running << ",  prof_data_map[tid].running_p " << prof_data_map[tid].running_p << endl;

    if (in_job_handler) return;
    // if (!running || !prof_data_map[tid].running_p) return;
    if (!running) return;

    in_job_handler++;
    Profiling::profiler_record_frames(data);
    in_job_handler--;
}

void Profiling::profiler_signal_handler(int sigint, siginfo_t *siginfo, void *ucontext) {
    static std::atomic_int in_signal_handler{0};

    if (in_signal_handler) return;
    if (!running) return;

    in_signal_handler++;
    rb_postponed_job_register_one(0, profiler_job_handler, (void *)0);
    // TODO how can I *ensure* this gets reset?
    in_signal_handler--;
}

void Profiling::profiling_start(pid_t tid) {
    prof_data_map[tid].md = Context::get();
    Logging::log_profile_entry(prof_data_map[tid].md,
                               prof_data_map[tid].prof_op_id,
                               tid,
                               interval);
    prof_data_map[tid].prev_num = 0;
    prof_data_map[tid].omitted_num = 0;
    prof_data_map[tid].running_p = true;

    // int num = rb_profile_frames(0, sizeof(frames_buffer) / sizeof(VALUE), frames_buffer, lines_buffer);
    // cout << "***** Current num frames: " << num << endl;

    if(cached_frames.load_factor() > (cached_frames.max_load_factor())/2.0)
        cached_frames.reserve(cached_frames.bucket_count() * 2);
    else if (cached_frames.bucket_count() < 1024)
        cached_frames.reserve(1024);

    if (!running) {
        // the signal is sent to the process and then one thread,
        // timer/signal may already be running
        struct sigaction sa;
        struct itimerval timer;

        // TODO figure out the mask and threads thing
        // TODO figure out what happens if there is another action for the same signal
        // => last one defined wins!
        // set up signal handler and timer
        sa.sa_sigaction = profiler_signal_handler;
        sa.sa_flags = SA_RESTART | SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGALRM, &sa, NULL);

        timer.it_interval.tv_sec = 0;
        timer.it_interval.tv_usec = interval * 1000;
        timer.it_value = timer.it_interval;
        setitimer(ITIMER_REAL, &timer, 0);
    }

    running++;

    // return Qtrue;
}

VALUE Profiling::profiling_stop(pid_t tid) {
    if (!running) return Qfalse;

    running--;

    if (!running) {
        // no threads are profiling -> stop global timer/signal
        struct sigaction sa;
        struct itimerval timer;

        memset(&timer, 0, sizeof(timer));
        setitimer(ITIMER_REAL, &timer, 0);

        sa.sa_handler = SIG_IGN;
        sa.sa_flags = SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGALRM, &sa, NULL);
    }

    Logging::log_profile_exit(prof_data_map[tid].md,
                              prof_data_map[tid].prof_op_id,
                              tid,
                              prof_data_map[tid].omitted,
                              prof_data_map[tid].omitted_num);

    prof_data_map[tid].running_p = false;

    return Qtrue;
}

VALUE Profiling::set_interval(VALUE self, VALUE val) {
    if (!FIXNUM_P(val)) return Qfalse;

    interval = FIX2INT(val);

    // TODO remove this condition once the fileReporter is changed to return -1 for oboe_get_profiling_interval()
    if (!getenv("APPOPTICS_REPORTER") || strcmp(getenv("APPOPTICS_REPORTER"), "file") != 0)
        interval = max(interval, (long)oboe_get_profiling_interval());
    // cout << "--- Profiling interval set to " << interval << endl;
    return Qtrue;
}

VALUE Profiling::get_interval() {
    return INT2FIX(interval);
}

VALUE Profiling::profiling_run(VALUE self, VALUE rb_thread_val) {
    rb_need_block(); // checks if function is called with a block in Ruby

    pid_t tid = AO_GETTID;

    // cout << tid << " running? " << prof_data_map[tid].running_p << endl;

    if (prof_data_map[tid].running_p) return Qfalse;
    prof_data_map[tid].omitted_num = 0;

    // cout << "starting profiling for tid " << tid << endl;

    profiling_start(tid);
    rb_ensure(reinterpret_cast<VALUE (*)(...)>(rb_yield), Qundef,
              reinterpret_cast<VALUE (*)(...)>(profiling_stop), tid);

    return Qtrue;
}

VALUE Profiling::getTid() {
    pid_t tid = AO_GETTID;

    return INT2NUM(tid);
}

static void
stackprof_atfork_prepare(void) {
    // cout << "Parent getting ready" << endl;
    struct itimerval timer;
    if (running) {
        memset(&timer, 0, sizeof(timer));
        setitimer(ITIMER_REAL, &timer, 0);
    }
}

static void
stackprof_atfork_parent(void) {
    // cout << "Parent let child loose" << endl;
    struct itimerval timer;
    if (running) {
        timer.it_interval.tv_sec = 0;
        timer.it_interval.tv_usec = interval;
        timer.it_value = timer.it_interval;
        setitimer(ITIMER_REAL, &timer, 0);
    }
}

static void
stackprof_atfork_child(void) {
    // cout << "A child is born" << endl;
}

extern "C" void Init_profiling(void) {
    // creates Ruby Module: AppOpticsAPM::CProfiler
    static VALUE rb_mAppOpticsAPM = rb_define_module("AppOpticsAPM");
    static VALUE rb_mCProfiler = rb_define_module_under(rb_mAppOpticsAPM, "CProfiler");

    rb_define_singleton_method(rb_mCProfiler, "get_interval", reinterpret_cast<VALUE (*)(...)>(Profiling::get_interval), 0);
    rb_define_singleton_method(rb_mCProfiler, "set_interval", reinterpret_cast<VALUE (*)(...)>(Profiling::set_interval), 1);
    rb_define_singleton_method(rb_mCProfiler, "run", reinterpret_cast<VALUE (*)(...)>(Profiling::profiling_run), 1);
    rb_define_singleton_method(rb_mCProfiler, "get_tid", reinterpret_cast<VALUE (*)(...)>(Profiling::getTid), 0);

    // TODO better understand pthread_atfork
    pthread_atfork(stackprof_atfork_prepare,
                   stackprof_atfork_parent,
                   stackprof_atfork_child);

    // TODO better understand the gc marking
    // ____ does it last forever or is it reset after a gc?
    for (int i = 0; i < BUF_SIZE; i++) rb_gc_mark(frames_buffer[i]);
}

