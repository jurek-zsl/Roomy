import SwiftUI

/// One model picker per installed AI, filled from that tool's own list.
struct AIModelPickers: View {
    @State private var lists: [CLIAdvisor.Tool: [AIModel]] = [:]
    @State private var choices: [CLIAdvisor.Tool: String] = [:]
    @State private var loading = true

    private var tools: [CLIAdvisor.Tool] { CLIAdvisor.Tool.allCases.filter { CLIAdvisor.locate($0.command) != nil } }

    var body: some View {
        Group {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking each AI for its models…").foregroundStyle(.secondary)
                }
            }
            ForEach(tools.filter { lists[$0] != nil }, id: \.self) { tool in
                let list = lists[tool] ?? []
                Picker(selection: binding(tool)) {
                    Text("Recommended: \(CLIAdvisor.recommended(tool, in: list)?.name ?? "its fastest")").tag("")
                    Text("Its own default").tag("default")
                    Divider()
                    ForEach(list) { m in
                        Text(m.note.map { "\(m.name) — \($0)" } ?? m.name).tag(m.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        ToolIcon(tool: tool, size: 16)
                        Text("\(tool.title) model")
                    }
                }
            }
            Text("Explaining folders is an easy task, so the recommended model is each AI's cheapest fast one. It uses less of your plan and answers sooner. Each list comes from the AI's own command.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            for tool in tools {
                guard let binary = CLIAdvisor.locate(tool.command) else { continue }
                lists[tool] = await Task.detached { CLIAdvisor.models(tool, binary: binary) }.value
                choices[tool] = CLIAdvisor.choice(tool)
            }
            loading = false
        }
    }

    private func binding(_ tool: CLIAdvisor.Tool) -> Binding<String> {
        Binding(get: { choices[tool] ?? "" }, set: {
            choices[tool] = $0
            UserDefaults.standard.set($0, forKey: CLIAdvisor.choiceKey(tool))
        })
    }
}
