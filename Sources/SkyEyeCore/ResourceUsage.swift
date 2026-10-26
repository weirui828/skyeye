import Darwin
import Foundation

/// CPU time and resident memory of a whole process group: a service plus everything it spawned.
public struct GroupUsage: Sendable {
    /// Total user + system CPU time, in nanoseconds.
    public var cpuTime: UInt64
    /// Resident memory, in bytes.
    public var memory: UInt64

    /// proc_taskinfo reports CPU time in Mach absolute time units (not nanoseconds on Apple Silicon).
    private static let nanosPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    public static func sample(pgid: pid_t) -> GroupUsage? {
        sample(pids: processIDs(pgid: pgid))
    }

    static func processIDs(pgid: pid_t) -> Set<pid_t> {
        var pids = [pid_t](repeating: 0, count: 1024)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return Set(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 })
    }

    static func processTree(root: pid_t) -> Set<pid_t> {
        var result: Set<pid_t> = [root]
        var pending = [root]
        while let parent = pending.popLast() {
            var children = [pid_t](repeating: 0, count: 1024)
            let bytes = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            for child in children.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where child > 0 {
                if result.insert(child).inserted { pending.append(child) }
            }
        }
        return result
    }

    static func sample(pids: Set<pid_t>) -> GroupUsage? {
        var ticks: UInt64 = 0
        var memory: UInt64 = 0
        var sampled = false
        for pid in pids {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            sampled = true
            ticks += info.pti_total_user + info.pti_total_system
            memory += info.pti_resident_size
        }
        return sampled ? GroupUsage(cpuTime: UInt64(Double(ticks) * nanosPerTick), memory: memory) : nil
    }
}

public struct ResourceUsage: Equatable, Sendable {
    /// Percent of total machine CPU capacity, matching the whole-computer reading.
    public var cpuPercent: Double?
    public var memoryBytes: UInt64

    public var summary: String {
        let cpu = cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        let memory = ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
        return "CPU " + cpu + " · " + memory
    }
}

struct ResourceSampler {
    private var previous: [pid_t: (start: UInt64, cpu: UInt64)] = [:]
    private var sampledAt: Date?

    mutating func sample(pids: Set<pid_t>, now: Date = Date()) -> ResourceUsage {
        var current: [pid_t: (start: UInt64, cpu: UInt64)] = [:]
        var cpuDelta: UInt64 = 0
        var memory: UInt64 = 0
        for pid in pids {
            guard let start = ManagedProcess.startTime(of: pid), let usage = GroupUsage.sample(pids: [pid]) else { continue }
            current[pid] = (start, usage.cpuTime)
            memory += usage.memory
            if let last = previous[pid], last.start == start, usage.cpuTime >= last.cpu {
                cpuDelta += usage.cpuTime - last.cpu
            }
        }
        let elapsed = sampledAt.map { now.timeIntervalSince($0) }
        let cpu = elapsed.flatMap { interval -> Double? in
            guard interval > 0 else { return nil }
            return min(100, Double(cpuDelta) / (interval * 1e9 * Double(ProcessInfo.processInfo.activeProcessorCount)) * 100)
        }
        previous = current
        sampledAt = now
        return ResourceUsage(cpuPercent: pids.isEmpty ? 0 : cpu, memoryBytes: memory)
    }
}

/// Whole-machine CPU and memory, for the menu bar header.
public struct SystemUsage: Equatable, Sendable {
    /// Across all cores, 0–100. Nil until there are two samples to compare.
    public var cpuPercent: Double?
    /// Counted like Activity Monitor's "Memory Used": app memory + wired + compressed.
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64

    /// "CPU 12% · 18.2/32 GB"
    public var summary: String {
        let gb = 1_073_741_824.0
        let memory = String(format: "%.1f/%.0f GB", Double(memoryUsed) / gb, Double(memoryTotal) / gb)
        guard let cpuPercent else { return memory }
        return String(format: "CPU %.0f%% · ", cpuPercent) + memory
    }
}

struct SystemSampler {
    private static let host = mach_host_self()
    private var lastTicks: (busy: UInt64, total: UInt64)?

    mutating func sample() -> SystemUsage? {
        guard let memoryUsed = Self.memoryUsed() else { return nil }
        var cpu: Double?
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total) * 100
            }
            lastTicks = ticks
        }
        return SystemUsage(cpuPercent: cpu, memoryUsed: memoryUsed, memoryTotal: ProcessInfo.processInfo.physicalMemory)
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    private static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(pageSize)
    }
}
