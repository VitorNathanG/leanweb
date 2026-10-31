// Copyright (c) 2026 Vitor Nathan Gonçalves.
#pragma once

#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <ctime>
#include <unistd.h>

namespace lean_io_profile {

enum class metric : unsigned {
    thread_create, thread_entry, thread_finalize, stack_setup, stack_teardown,
    loop_acquire_fast, loop_acquire_contended, loop_iteration,
    task_wait, task_wait_any, task_resolve, count
};

struct alignas(64) counter {
    std::atomic<uint64_t> calls{0};
    std::atomic<uint64_t> wall_ns{0};
    std::atomic<uint64_t> cpu_ns{0};
    std::atomic<uint64_t> buckets[64]{};
};

static_assert(std::atomic<uint64_t>::is_always_lock_free);
inline counter counters[static_cast<unsigned>(metric::count)];
inline char const * const names[] = {
    "thread_create", "thread_entry", "thread_finalize", "stack_setup", "stack_teardown",
    "loop_acquire_fast", "loop_acquire_contended", "loop_iteration",
    "task_wait", "task_wait_any", "task_resolve"
};

inline uint64_t now(clockid_t clock) {
    timespec value{};
    if (clock_gettime(clock, &value) != 0) _exit(120);
    return static_cast<uint64_t>(value.tv_sec) * 1000000000 + value.tv_nsec;
}

class scope {
    metric m_metric;
    uint64_t m_wall;
    uint64_t m_cpu;
    bool m_measure_cpu;
public:
    explicit scope(metric value, bool measure_cpu = true):
        m_metric(value), m_wall(now(CLOCK_MONOTONIC)),
        m_cpu(measure_cpu ? now(CLOCK_THREAD_CPUTIME_ID) : 0), m_measure_cpu(measure_cpu) {}
    scope(scope const &) = delete;
    scope & operator=(scope const &) = delete;
    void classify(metric value) { m_metric = value; }
    ~scope() {
        auto cpu = m_measure_cpu ? now(CLOCK_THREAD_CPUTIME_ID) - m_cpu : 0;
        auto wall = now(CLOCK_MONOTONIC) - m_wall;
        auto & result = counters[static_cast<unsigned>(m_metric)];
        result.calls.fetch_add(1, std::memory_order_relaxed);
        result.wall_ns.fetch_add(wall, std::memory_order_relaxed);
        result.cpu_ns.fetch_add(cpu, std::memory_order_relaxed);
        result.buckets[63 - __builtin_clzll(wall | 1)].fetch_add(1, std::memory_order_relaxed);
    }
};

// SIGUSR1 only reads lock-free counters and writes a bounded buffer. Samples are
// approximate across counters; the collector takes differences between snapshots.
inline void snapshot(int) {
    int saved_errno = errno;
    char output[32768];
    size_t size = 0;
    auto character = [&](char c) {
        if (size == sizeof(output)) _exit(121);
        output[size++] = c;
    };
    auto text = [&](char const * s) { while (*s) character(*s++); };
    auto number = [&](uint64_t value) {
        char digits[20];
        unsigned count = 0;
        do { digits[count++] = '0' + value % 10; value /= 10; } while (value);
        while (count) character(digits[--count]);
    };
    text("{\"runtime_profile\":{");
    for (unsigned i = 0; i < static_cast<unsigned>(metric::count); ++i) {
        if (i) character(',');
        character('"'); text(names[i]); text("\":{\"calls\":");
        auto & result = counters[i];
        number(result.calls.load(std::memory_order_relaxed));
        text(",\"wall_ns\":"); number(result.wall_ns.load(std::memory_order_relaxed));
        text(",\"cpu_ns\":"); number(result.cpu_ns.load(std::memory_order_relaxed));
        text(",\"wall_log2_ns\":[");
        for (unsigned bucket = 0; bucket < 64; ++bucket) {
            if (bucket) character(',');
            number(result.buckets[bucket].load(std::memory_order_relaxed));
        }
        text("]}");
    }
    text("}}\n");
    size_t written = 0;
    while (written < size) {
        auto result = write(STDERR_FILENO, output + written, size - written);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) _exit(122);
        written += static_cast<size_t>(result);
    }
    errno = saved_errno;
}

struct installer {
    installer() {
        struct sigaction action{};
        action.sa_handler = snapshot;
        action.sa_flags = SA_RESTART;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGUSR1, &action, nullptr) != 0) _exit(123);
    }
};
inline installer install;

}
