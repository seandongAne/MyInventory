//
//  PresetValuePicker.swift
//  MyInventory
//
//  Form control for "pick a common value or dial in a custom one": a menu
//  Picker over preset values plus a Custom mode that reveals a Stepper.
//  Replaces bare Steppers for values like "24 months" that would otherwise
//  take dozens of taps to reach.
//

import SwiftUI

struct PresetValuePicker: View {
    let label: String
    @Binding var value: Int
    let presets: [Int]
    let range: ClosedRange<Int>
    let format: (Int) -> String

    @State private var isCustom: Bool

    init(_ label: String,
         value: Binding<Int>,
         presets: [Int],
         range: ClosedRange<Int>,
         format: @escaping (Int) -> String) {
        self.label = label
        self._value = value
        self.presets = presets
        self.range = range
        self.format = format
        _isCustom = State(initialValue: !presets.contains(value.wrappedValue))
    }

    private var selection: Binding<Int> {
        Binding(
            get: { (isCustom || !presets.contains(value)) ? -1 : value },
            set: { picked in
                if picked == -1 {
                    isCustom = true
                } else {
                    isCustom = false
                    value = picked
                }
            }
        )
    }

    var body: some View {
        Group {
            Picker(label, selection: selection) {
                ForEach(presets, id: \.self) { preset in
                    Text(format(preset)).tag(preset)
                }
                Text("Custom…").tag(-1)
            }
            .onChange(of: value) { _, newValue in
                // External writes (e.g. defaults applied on appear) may land on
                // a non-preset value — flip to custom so the picker doesn't lie.
                if !presets.contains(newValue) { isCustom = true }
            }

            if isCustom {
                Stepper(value: $value, in: range) {
                    LabeledContent("Custom", value: format(value))
                }
            }
        }
    }
}
