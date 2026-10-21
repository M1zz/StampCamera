//
//  StampCameraRoadmap.swift
//  StampCamera
//
//  **앞으로 만들 것**의 원본. 설정 ▸ 지원 ▸ 앞으로 만들 기능(`LeeoRoadmapView`)이 이 목록을 그대로 보여 준다.
//
//  ⚠️ 개발하다 "이건 다음에" 가 생기면 **여기에 한 줄을 더한다.** 코드의 TODO 주석으로만 남기지 않는다.
//     - 새 항목: `.planned`. 손대기 시작하면 `.building`. 내보내면 `.shipped("1.2.0")`.
//     - id 는 한 번 정하면 바꾸지 않는다(문구는 바꿔도 된다). 같은 피처는 다른 앱과 같은 id 를 쓴다.
//     - 문구는 사용자 말로 쓴다(내부 이름 · 기술 용어 금지). 영어는 StampCamera/Localizable.xcstrings 에 넣는다
//       (앱의 다른 화면은 한국어 하나지만, 이 화면 문구만은 en · ko 를 둘 다 둔다).
//     - 사용자에게 보일 만한 것만 적는다. 리팩터링 · 시험 · 빌드 설정은 `.sprintcommander/tasks.json` 의 몫이다.
//

import SwiftUI
import LeeoKit

extension StampCameraSpec {
    static var roadmap: [LeeoRoadmapItem] {[
        // MARK: 다음에 만들어요
        .init(id: "a11y.voiceover", status: .planned,
              title: NSLocalizedString("VoiceOver로 더 편하게", comment: "Roadmap item: better VoiceOver support"),
              detail: NSLocalizedString("화면 읽기 기능이 단추와 스티커를 빠짐없이, 알맞은 순서로 읽어 줘요.", comment: "Roadmap item detail: better VoiceOver support")),
        .init(id: "a11y.largetext", status: .planned,
              title: NSLocalizedString("큰 글씨에 맞춘 화면", comment: "Roadmap item: Dynamic Type layouts"),
              detail: NSLocalizedString("글자 크기를 키워도 잘리지 않고 보기 좋게 다시 배치돼요.", comment: "Roadmap item detail: Dynamic Type layouts")),
        .init(id: "a11y.contrast", status: .planned,
              title: NSLocalizedString("보기 편한 색과 대비", comment: "Roadmap item: contrast and color"),
              detail: NSLocalizedString("대비를 높이거나 색을 구별하기 어려워도 내용을 알아볼 수 있어요.", comment: "Roadmap item detail: contrast and color")),
        .init(id: "a11y.motion", status: .planned,
              title: NSLocalizedString("움직임 줄이기", comment: "Roadmap item: reduce motion"),
              detail: NSLocalizedString("움직임 줄이기를 켜면 화면 효과가 차분해져요.", comment: "Roadmap item detail: reduce motion")),
        .init(id: "lang.english", status: .planned,
              title: NSLocalizedString("영어 지원", comment: "Roadmap item: English"),
              detail: NSLocalizedString("앱을 영어로도 쓸 수 있어요.", comment: "Roadmap item detail: English")),
        .init(id: "lang.more", status: .planned,
              title: NSLocalizedString("더 많은 언어", comment: "Roadmap item: more languages"),
              detail: NSLocalizedString("더 많은 나라 말로 앱을 쓸 수 있게 해요.", comment: "Roadmap item detail: more languages")),
        .init(id: "onboarding", status: .planned,
              title: NSLocalizedString("처음 쓰는 분을 위한 안내", comment: "Roadmap item: onboarding"),
              detail: NSLocalizedString("처음 열었을 때 스티커를 뜯고 쓰는 법을 짧게 보여 줘요.", comment: "Roadmap item detail: onboarding")),
        .init(id: "whatsnew", status: .planned,
              title: NSLocalizedString("업데이트 소식", comment: "Roadmap item: what's new"),
              detail: NSLocalizedString("업데이트 뒤 처음 열 때 무엇이 새로 생겼는지 알려 줘요.", comment: "Roadmap item detail: what's new")),
        .init(id: "sync.icloud", status: .planned,
              title: NSLocalizedString("기기 간 동기화", comment: "Roadmap item: iCloud sync"),
              detail: NSLocalizedString("새 아이폰으로 바꿔도 모은 스티커가 iCloud로 그대로 이어져요.", comment: "Roadmap item detail: iCloud sync")),
        .init(id: "backup", status: .planned,
              title: NSLocalizedString("스티커 백업과 내보내기", comment: "Roadmap item: backup and export"),
              detail: NSLocalizedString("모은 스티커를 파일로 저장하고 다시 불러올 수 있어요.", comment: "Roadmap item detail: backup and export")),
        .init(id: "lock.faceid", status: .planned,
              title: NSLocalizedString("Face ID 잠금", comment: "Roadmap item: Face ID lock"),
              detail: NSLocalizedString("Face ID로 앱을 잠가 내 수집함을 지켜요.", comment: "Roadmap item detail: Face ID lock")),
        .init(id: "notifications", status: .planned,
              title: NSLocalizedString("지난 스티커 알림", comment: "Roadmap item: notifications"),
              detail: NSLocalizedString("작년 오늘 뜯은 스티커를 알림으로 다시 꺼내 보여 줘요.", comment: "Roadmap item detail: notifications")),
        .init(id: "fold", status: .planned,
              title: NSLocalizedString("펼치는 아이폰 화면", comment: "Roadmap item: foldable iPhone layout"),
              detail: NSLocalizedString("펼치는 아이폰에서 넓은 화면을 두 쪽으로 나눠 써요.", comment: "Roadmap item detail: foldable iPhone layout")),
        .init(id: "data.delete", status: .planned,
              title: NSLocalizedString("스티커 한 번에 지우기", comment: "Roadmap item: delete all data"),
              detail: NSLocalizedString("원하면 앱 안에서 모은 스티커를 모두 지울 수 있어요.", comment: "Roadmap item detail: delete all data")),
        .init(id: "print.cutout", status: .planned,
              title: NSLocalizedString("오려낸 모양 그대로 인쇄", comment: "Roadmap item: print cut-out stickers in their own shape"),
              detail: NSLocalizedString("인쇄용 스티커 시트에서 오려낸 스티커는 우표 모양이 아니라 오려낸 윤곽 그대로 칼선이 들어가요.", comment: "Roadmap item detail: print cut-out stickers in their own shape")),
        .init(id: "album.freeplace", status: .planned,
              title: NSLocalizedString("수집함 페이지에 마음대로 붙이기", comment: "Roadmap item: free placement on album pages"),
              detail: NSLocalizedString("칸에 맞추지 않고, 속지 위 원하는 자리에 스티커를 비스듬히 붙여 꾸밀 수 있어요.", comment: "Roadmap item detail: free placement on album pages")),
        .init(id: "autosave", status: .planned,
              title: NSLocalizedString("하던 일 이어서 하기", comment: "Roadmap item: keep unsaved work"),
              detail: NSLocalizedString("수집함을 꾸미다가 앱이 꺼져도 하던 내용이 남아 있어요.", comment: "Roadmap item detail: keep unsaved work")),
    ]}
}

// MARK: - 화면

/// 설정 ▸ 앞으로 만들 기능. "이런 기능이 있으면 좋겠어요" 는 기능 제안으로 시작하는 피드백 창을 연다.
struct RoadmapScreen: View {
    @State private var showFeedback = false

    var body: some View {
        LeeoRoadmapView<StampCameraSpec>(onSuggest: { showFeedback = true })
            .sheet(isPresented: $showFeedback) {
                NavigationStack {
                    LeeoFeedbackView<StampCameraSpec>(initialType: .feature)
                }
            }
    }
}
