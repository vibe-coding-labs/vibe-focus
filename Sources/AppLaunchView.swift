import SwiftUI

struct AppLaunchView: View {
    @StateObject private var launcher = AppLauncher.shared
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 24) {
            // 图标
            Image(systemName: "viewfinder.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            // 标题
            Text("VibeFocus")
                .font(.largeTitle)
                .fontWeight(.semibold)

            // 进度条
            VStack(spacing: 8) {
                ProgressView(value: launcher.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)

                Text(launcher.currentPhase.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 状态信息
            if let error = launcher.launchError {
                LaunchErrorView(error: error)
            } else if launcher.currentPhase == .completed {
                LaunchSuccessView()
            }

            // 详情开关
            if !launcher.phaseResults.isEmpty {
                Button(showDetails ? "隐藏详情" : "显示详情") {
                    withAnimation {
                        showDetails.toggle()
                    }
                }
                .buttonStyle(.link)
            }

            // 详情列表
            if showDetails {
                LaunchDetailsList(results: launcher.phaseResults)
                    .frame(maxHeight: 200)
            }

            // 健康检查结果
            if !launcher.healthResults.isEmpty {
                HealthCheckSummary(results: launcher.healthResults)
            }
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 300)
    }
}

// MARK: - Subviews

struct LaunchErrorView: View {
    let error: LaunchError

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)

            Text(error.localizedDescription)
                .font(.headline)

            Text(error.recoverySuggestion)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("打开系统设置") {
                    error.openSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("重试") {
                    Task {
                        await AppLauncher.shared.launch()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}

struct LaunchSuccessView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("启动成功")
                .foregroundStyle(.secondary)
        }
    }
}

struct LaunchDetailsList: View {
    let results: [LaunchPhaseResult]

    var body: some View {
        List(results) { result in
            HStack {
                Image(systemName: result.success ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(result.success ? .green : .red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.phase.rawValue)
                        .font(.caption)
                        .fontWeight(.medium)

                    if let message = result.message {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(String(format: "%.3fs", result.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }
}

struct HealthCheckSummary: View {
    let results: [LaunchHealthChecker.HealthCheckResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("健康检查")
                .font(.caption)
                .fontWeight(.medium)

            ForEach(results, id: \.component) { result in
                HStack {
                    Image(systemName: iconName(for: result))
                        .foregroundStyle(color(for: result))

                    Text(result.component)
                        .font(.caption2)

                    Spacer()

                    Text(result.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func iconName(for result: LaunchHealthChecker.HealthCheckResult) -> String {
        switch result.severity {
        case .info:
            return result.isHealthy ? "checkmark.circle" : "info.circle"
        case .warning:
            return result.isHealthy ? "checkmark.circle" : "exclamationmark.triangle"
        case .critical:
            return result.isHealthy ? "checkmark.circle" : "xmark.octagon"
        }
    }

    private func color(for result: LaunchHealthChecker.HealthCheckResult) -> Color {
        switch result.severity {
        case .info:
            return result.isHealthy ? .green : .blue
        case .warning:
            return result.isHealthy ? .green : .orange
        case .critical:
            return result.isHealthy ? .green : .red
        }
    }
}

// MARK: - Extensions

extension LaunchPhaseResult: Identifiable {
    var id: String { phase.rawValue }
}

extension LaunchError {
    func openSettings() {
        switch self {
        case .accessibilityPermissionDenied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .invalidInstallationLocation:
            if let url = URL(string: "file:///Applications") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AppLaunchView_Previews: PreviewProvider {
    static var previews: some View {
        AppLaunchView()
    }
}
#endif
