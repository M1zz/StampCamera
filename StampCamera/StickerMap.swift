//
//  StickerMap.swift
//  StampCamera
//
//  지도에서 스티커 보기: 찍은 자리에 스티커가 놓인다.
//  한 자리(사진 한 장)에서 딴 스티커들은 한 무더기로 겹쳐 놓이고, 누르면 그 자리의 스티커들이 펼쳐진다.
//

import SwiftUI
import MapKit

/// 한 자리에 놓인 스티커들.
struct StickerSpot: Identifiable {
    let id: String                     // 무더기 맨 위 스티커
    let coordinate: CLLocationCoordinate2D
    let stamps: [CollectedStamp]       // 새것부터

    /// 거의 같은 자리(약 10m 안)의 스티커를 한 무더기로 묶는다.
    static func group(_ stamps: [CollectedStamp]) -> [StickerSpot] {
        var buckets: [String: [CollectedStamp]] = [:]
        var order: [String] = []
        for s in stamps.reversed() {
            guard let c = s.coordinate else { continue }
            let key = String(format: "%.4f,%.4f", c.latitude, c.longitude)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(s)
        }
        return order.compactMap { key in
            guard let list = buckets[key], let top = list.first, let c = top.coordinate else { return nil }
            return StickerSpot(id: top.id, coordinate: c, stamps: list)
        }
    }
}

struct StickerMapView: View {
    @ObservedObject var collection: CollectionStore
    @State private var opened: StickerSpot?

    var body: some View {
        let spots = StickerSpot.group(collection.stamps)
        Group {
            if spots.isEmpty {
                ContentUnavailableView {
                    Label("지도에 놓을 스티커가 없어요", systemImage: "map")
                } description: {
                    Text("위치를 허용하고 찍으면 찍은 자리에 스티커가 놓여요")
                }
            } else {
                Map(initialPosition: .automatic) {
                    ForEach(spots) { spot in
                        Annotation(spot.stamps.first?.place ?? "", coordinate: spot.coordinate) {
                            Button {
                                Haptics.tick()
                                opened = spot
                            } label: { pile(spot) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(spot.stamps.first?.place ?? ""))
                            .accessibilityValue(Text("\(spot.stamps.count)장"))
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapControls { MapUserLocationButton(); MapCompass() }
            }
        }
        .navigationTitle("지도")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $opened) { spot in
            NavigationStack { SpotSheet(collection: collection, spot: spot) }
                .presentationDetents(spot.stamps.count == 1 ? [.large] : [.medium, .large])
        }
    }

    /// 지도 위 무더기: 맨 위 스티커와 그 밑에 살짝 비껴 쌓인 두 장, 여럿이면 수.
    private func pile(_ spot: StickerSpot) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(Array(spot.stamps.prefix(3).enumerated().reversed()), id: \.element.id) { i, s in
                    Image(uiImage: s.image).resizable().scaledToFit()
                        .frame(width: 54, height: 54)
                        .rotationEffect(.degrees(Double(i) * 9))
                        .offset(x: CGFloat(i) * 5, y: CGFloat(i) * -3)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            if spot.stamps.count > 1 {
                Text(verbatim: "\(spot.stamps.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green))
                    .offset(x: 8, y: -6)
            }
        }
        .frame(width: 66, height: 66)
    }
}

/// 한 자리의 스티커들. 하나뿐이면 바로 그 스티커를 연다.
private struct SpotSheet: View {
    @ObservedObject var collection: CollectionStore
    let spot: StickerSpot

    var body: some View {
        if spot.stamps.count == 1, let only = spot.stamps.first {
            StampDetailView(collection: collection, stampID: only.id)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 16) {
                    ForEach(spot.stamps) { stamp in
                        NavigationLink {
                            StampDetailView(collection: collection, stampID: stamp.id)
                        } label: {
                            LiveArt(collection: collection, stamp: stamp).frame(height: 96)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle(spot.stamps.first?.place.isEmpty == false ? spot.stamps[0].place
                             : spot.stamps[0].createdAt.formatted(date: .abbreviated, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
