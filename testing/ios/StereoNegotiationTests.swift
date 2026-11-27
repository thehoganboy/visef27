import Foundation

@main
struct StereoNegotiationTests {
    static func main() {
        typealias Negotiation = StereoNegotiation
        precondition(Negotiation.supportedPairs(in: [["wide", "ultrawide"], ["tele"]]) == [["wide", "ultrawide"]])
        precondition(Negotiation.supportedPairs(in: [["wide"], ["tele"]]).isEmpty)
        precondition(Negotiation.supportedPairs(in: [["wide", "ultrawide", "tele"]]).count == 3)

        let rates = Negotiation.Rate.candidates
        let thirty = rates[0], twentyFour = rates[2], fifteen = rates[4]
        func format(_ id: Int, _ width: Int, _ rates: [Negotiation.Rate], multicam: Bool = true) -> Negotiation.Format {
            .init(id: id, multicam: multicam, width: width, height: width * 3 / 4,
                  pixelFormat: 875704438, binned: width < 800, fov: 65, rates: rates)
        }
        let a = [format(0, 320, [thirty, twentyFour, fifteen], multicam: false),
                 format(1, 960, [thirty, twentyFour, fifteen]), format(2, 640, [fifteen])]
        let b = [format(3, 640, [thirty, fifteen]), format(4, 960, [twentyFour])]
        let plans = Negotiation.candidates(a, b)
        precondition(plans.map(\.rate) == [thirty, twentyFour, fifteen, fifteen])
        precondition(plans.allSatisfy { $0.a != 0 })
        precondition(plans[2].a == 2 && plans[2].b == 3)
        precondition(Negotiation.candidates([format(1, 640, [thirty])], [format(2, 640, [fifteen])]).isEmpty)
        let preferred = Negotiation.candidates(a, b, preferred: [a[1].signature, b[0].signature])
        precondition(preferred[2].a == 1)

        // Simulate hardware cost rejection and a partially installed graph before a successful fallback.
        var graph: [Int] = []
        var failures: [String] = []
        var selected: Negotiation.Rate?
        for plan in plans {
            precondition(graph.isEmpty)
            graph.append(plan.a)
            if plan.rate == twentyFour {
                failures.append("partial configuration")
                graph.removeAll()
                continue
            }
            graph.append(plan.b)
            if plan.rate == thirty {
                failures.append("hardware cost")
                graph.removeAll()
                continue
            }
            selected = plan.rate
            break
        }
        precondition(failures == ["hardware cost", "partial configuration"] && selected == fifteen)
        var delivery = Negotiation.Delivery()
        precondition(!delivery.ready)
        for _ in 0..<8 { delivery.sample(timestamp: nil, rejection: "dropped") }
        precondition(!delivery.ready && delivery.rejected == 8)
        for index in 0..<12 { delivery.sample(timestamp: 100 + Double(index) / 15) }
        precondition(delivery.ready && abs(delivery.fps - 15) < 0.001)
        delivery.sample(timestamp: 100)
        precondition(delivery.rejected == 9 && delivery.rejection == "nonmonotonic timestamp")
        for _ in 0..<12 { delivery.sample(timestamp: nil, rejection: "interrupted") }
        precondition(!delivery.ready && delivery.consecutiveRejected == 13)

        var epoch = DepthSourceEpoch()
        let original = epoch.value
        for _ in 0..<3 { epoch.invalidate() }
        precondition(!epoch.accepts(original, timestamp: 120, now: 120.1, after: 0))
        precondition(epoch.accepts(epoch.value, timestamp: 120, now: 120.1, after: 0))
        print("PASS 19 negotiation, simulated fallback, delivery and stale-generation checks")
    }
}
