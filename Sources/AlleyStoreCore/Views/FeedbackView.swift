import AlleyShared
import SwiftUI

/// 앱 하나에 달린 피드백과, 남기는 자리.
///
/// 받아본 사람만 남길 수 있다(서버 규칙). 설치한 적이 없으면 폼 대신 그 사실을
/// 적는다. 누를 수 있는 폼을 보여주고 거절하는 것보다 낫다.
struct FeedbackSection: View {
    @Environment(StoreModel.self) private var model
    let app: AppDTO
    /// 남길 수 있는 버전. 설치한 버전이 없으면 nil 이다.
    let reviewableVersion: VersionDTO?
    /// 익명 체크박스를 띄울지. 스토어 설정에서 온다.
    let allowsAnonymous: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("피드백").font(.headline)
                Spacer()
                if let rating = app.rating, let average = rating.displayAverage {
                    Text("★ \(average) · \(rating.count)명")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let version = reviewableVersion {
                FeedbackForm(app: app, version: version, allowsAnonymous: allowsAnonymous)
            } else {
                Text("받아본 버전에만 남길 수 있습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.isLoadingFeedback {
                ProgressView().controlSize(.small)
            } else if model.feedback.isEmpty {
                Text("아직 남긴 사람이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.feedback) { entry in
                    FeedbackRowView(entry: entry)
                }
            }
        }
    }
}

/// 별점과 글을 남기는 폼.
struct FeedbackForm: View {
    @Environment(StoreModel.self) private var model
    let app: AppDTO
    let version: VersionDTO
    let allowsAnonymous: Bool

    @State private var rating: Int?
    @State private var text = ""
    @State private var isAnonymous = false
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(version.shortVersion) (빌드 \(version.buildNumber)) 에 남깁니다")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { score in
                    Button {
                        // 같은 별을 다시 누르면 별점을 뺀다. 글만 남기고 싶을 수 있다.
                        rating = (rating == score) ? nil : score
                    } label: {
                        Image(systemName: (rating ?? 0) >= score ? "star.fill" : "star")
                            .foregroundStyle((rating ?? 0) >= score ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("별 \(score)개")
                }
                if rating != nil {
                    Button("지우기") { rating = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            TextEditor(text: $text)
                .frame(height: 70)
                .font(.body)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("무엇이 좋았고 무엇이 불편했는지")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator)
                }

            HStack {
                if allowsAnonymous {
                    Toggle("이름 숨기기", isOn: $isAnonymous)
                        .toggleStyle(.checkbox)
                        .help("화면에 이름이 뜨지 않습니다. 서버에는 기록이 남습니다.")
                }
                Spacer()
                Button("남기기", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit || isSubmitting)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 별점이든 글이든 하나는 있어야 한다. 서버도 같은 규칙이다.
    private var canSubmit: Bool {
        rating != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        isSubmitting = true
        Task {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sent = await model.submitFeedback(
                rating: rating,
                body: trimmed.isEmpty ? nil : trimmed,
                // 설정이 꺼진 채로 체크가 남아 있으면 서버가 거절한다. 여기서 막는다.
                isAnonymous: allowsAnonymous && isAnonymous,
                versionID: version.id,
                app: app
            )
            if sent {
                text = ""
                rating = nil
            }
            isSubmitting = false
        }
    }
}

/// 남겨진 피드백 한 줄.
struct FeedbackRowView: View {
    let entry: FeedbackDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let rating = entry.rating {
                    Text(String(repeating: "★", count: rating))
                        .foregroundStyle(.yellow)
                }
                Text(entry.author?.name ?? "익명")
                    .font(.callout.weight(.medium))
                Text(entry.versionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let body = entry.body {
                Text(body).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
