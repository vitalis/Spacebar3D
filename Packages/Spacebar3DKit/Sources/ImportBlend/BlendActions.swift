import Foundation

extension BlendFile {
    /// The blocks an array of pointers leads to, one entry a pointer (nil where a pointer
    /// leads nowhere), no more than the array has room for.
    func pointerArray(_ address: UInt64, count: Int) -> [Block?] {
        guard count > 0, let held = block(at: address) else { return [] }
        return (0..<min(count, held.length / pointerSize, Self.maxListLength)).map { block(at: pointer(held.offset + $0 * pointerSize)) }
    }

    /// The curves that animate a data-block (an object, a shape-key set): those of the slot of
    /// its action that it is assigned to, in the form Blender 4.4 and later save, with layers,
    /// slots and strips. An action in the older form (a plain list of curves) gives none.
    ///
    /// A layer above another replaces the curves of the same path and index; a strip's own
    /// time range and offset, a layer's influence, and curve modifiers are not read.
    func animationCurves(ofBlockAt index: Int) -> [BlendCurve] {
        guard blocks.indices.contains(index), let adtField = structure(of: blocks[index])?.fields["adt"], adtField.isPointer,
              let actionField = offset("AnimData", "action"), let handleField = offset("AnimData", "slot_handle"),
              let layersField = offset("bAction", "layer_array"), let layerCount = offset("bAction", "layer_array_num"),
              let slotsField = offset("bAction", "slot_array"), let slotCount = offset("bAction", "slot_array_num"),
              let dataField = offset("bAction", "strip_keyframe_data_array"), let dataCount = offset("bAction", "strip_keyframe_data_array_num"),
              let slotHandle = offset("ActionSlot", "handle"),
              let stripsField = offset("ActionLayer", "strip_array"), let stripCount = offset("ActionLayer", "strip_array_num"),
              let stripType = offset("ActionStrip", "strip_type"), let stripData = offset("ActionStrip", "data_index"),
              let bagsField = offset("ActionStripKeyframeData", "channelbag_array"), let bagCount = offset("ActionStripKeyframeData", "channelbag_array_num"),
              let bagHandle = offset("ActionChannelBag", "slot_handle"),
              let curvesField = offset("ActionChannelBag", "fcurve_array"), let curveCount = offset("ActionChannelBag", "fcurve_array_num") else { return [] }
        let before = currentOwner
        defer { currentOwner = before }
        currentOwner = index
        guard let adt = block(at: pointer(blocks[index].offset + adtField.offset)),
              let action = dataBlock(at: pointer(adt.offset + actionField)), action.block.code == Self.code("AC") else { return [] }
        let handle = i32(adt.offset + handleField)
        currentOwner = action.index
        let base = action.block.offset
        // The slot this data-block is assigned to must be there, or nothing is animated.
        guard pointerArray(pointer(base + slotsField), count: Int(i32(base + slotCount))).contains(where: { $0.map { i32($0.offset + slotHandle) == handle } ?? false }) else { return [] }
        let data = pointerArray(pointer(base + dataField), count: Int(i32(base + dataCount)))
        var byName: [String: BlendCurve] = [:]
        var order: [String] = []
        for case let layer? in pointerArray(pointer(base + layersField), count: Int(i32(base + layerCount))) {
            for case let strip? in pointerArray(pointer(layer.offset + stripsField), count: Int(i32(layer.offset + stripCount))) {
                // Type 0 is the strip of keyframes, the only kind there is.
                let at = Int(i32(strip.offset + stripData))
                guard u8(strip.offset + stripType) == 0, data.indices.contains(at), let keyframes = data[at] else { continue }
                for case let bag? in pointerArray(pointer(keyframes.offset + bagsField), count: Int(i32(keyframes.offset + bagCount))) where i32(bag.offset + bagHandle) == handle {
                    for case let one? in pointerArray(pointer(bag.offset + curvesField), count: Int(i32(bag.offset + curveCount))) {
                        guard let curve = BlendCurve.read(one, in: self) else { continue }
                        let name = "\(curve.path)#\(curve.index)"
                        if byName[name] == nil { order.append(name) }
                        byName[name] = curve
                    }
                }
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// The name of the action a data-block is animated by (for naming the clip).
    func actionName(ofBlockAt index: Int) -> String? {
        guard blocks.indices.contains(index), let adtField = structure(of: blocks[index])?.fields["adt"], adtField.isPointer,
              let actionField = offset("AnimData", "action") else { return nil }
        let before = currentOwner
        defer { currentOwner = before }
        currentOwner = index
        guard let adt = block(at: pointer(blocks[index].offset + adtField.offset)),
              let action = dataBlock(at: pointer(adt.offset + actionField)), action.block.code == Self.code("AC") else { return nil }
        return name(of: action.block)
    }
}
