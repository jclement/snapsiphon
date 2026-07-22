import Foundation

/// Live process memory, as jetsam sees it (`phys_footprint`). Surfaced as a
/// dashboard gauge while uploading — after the multi-GB-video jetsam bug, this
/// number staying flat during a big backup is the proof the pipeline streams.
enum MemoryFootprint {
    static var currentMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
