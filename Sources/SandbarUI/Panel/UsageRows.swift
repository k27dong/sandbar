import SandbarCore
import SwiftUI

package struct UsageRows: View {
    @Environment(AppModel.self) private var model

    package init() {}

    package var body: some View {
        VStack(spacing: 0) {
            ForEach(model.snapshot.accounts) { entry in
                let reading = entry.limits
                let limits: [UsageLimit?] = reading.value.isEmpty ? [nil] : reading.value
                ForEach(limits.indices, id: \.self) { index in
                    UsageRow(
                        account: index == 0 ? entry.account : nil, limit: limits[index],
                        isDimmed: reading.trouble != nil
                    )
                    .help(reading.trouble == nil ? "" : reading.detail ?? "")
                }
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 1)
    }
}

private struct UsageRow: View {
    @Environment(AppModel.self) private var model
    let account: Account?
    let limit: UsageLimit?
    let isDimmed: Bool

    var body: some View {
        let mark: Icon? = account.map {
            switch $0.tool {
            case .claude: .claude
            case .codex: .codex
            }
        }
        let tone = Color.usage(limit?.level ?? .normal)
        let pace = model.preferences.showsPace ? limit?.pace(now: model.now) : nil
        HStack(spacing: 8) {
            ZStack {
                if let mark { mark.image.foregroundStyle(mark.tint ?? .primary) }
            }
            .frame(width: 16, alignment: .leading)
            Text(account?.name ?? "")
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            Text(limit?.label ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)
            Capsule()
                .fill(tone.opacity(0.2))
                .overlay(alignment: .leading) {
                    if let limit {
                        GeometryReader { bar in
                            Capsule().fill(tone).frame(width: max(3, bar.size.width * min(1, limit.used)))
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    if let pace {
                        GeometryReader { bar in
                            Rectangle().frame(width: 2).offset(x: bar.size.width * pace - 1).blendMode(.destinationOut)
                        }
                    }
                }
                .compositingGroup()
                .frame(height: 6)
                .opacity(isDimmed ? 0.4 : 1)
            Text(limit?.amount ?? "–")
                .font(.system(size: 12).monospacedDigit())
                .lineLimit(1)
                .frame(width: 50, alignment: .trailing)
                .opacity(isDimmed ? 0.4 : 1)
            Text(limit?.end(now: model.now).map { ShortTime.left(until: $0, from: model.now) } ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}
