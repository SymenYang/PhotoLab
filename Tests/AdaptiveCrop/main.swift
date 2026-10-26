import Foundation
import CoreGraphics
@main struct Tests {
    static func run(_ budget: Int, aspect: Double = 0.75, constant: Bool = false) -> AdaptiveCropSearch {
        var s = AdaptiveCropSearch(size:CGSize(width:4000,height:3000),aspect:aspect,area:0.3,budget:budget)
        var seen = Set<String>(), phases = Set<String>(), coarseBest = -Double.infinity
        while let p = s.next() {
            let r = p.rect
            precondition(r.minX >= 0 && r.minY >= 0 && r.maxX <= 4000 && r.maxY <= 3000)
            precondition(r.width*r.height >= 4000*3000*0.3 && abs(r.width/r.height-aspect)<0.001)
            precondition(seen.insert(String(describing:r)).inserted,"duplicate model evaluation")
            let score = constant ? 0.5 : exp(-12*(pow(r.midX/4000-0.63,2)+pow(r.midY/3000-0.54,2)+pow(r.height/3000-0.81,2)))
            phases.insert(p.phase)
            if p.phase == "粗搜覆盖" { coarseBest = max(coarseBest,score) }
            s.record(score)
            precondition(s.evaluationCount <= budget)
        }
        precondition(s.samples.count <= budget && s.top().count == 5)
        precondition(s.globalCount >= min(s.evaluationCount,Int(Double(s.evaluationCount)*0.2)))
        if !constant { precondition(phases.contains("多路线细化")); precondition(s.top()[0].score >= coarseBest) }
        print("budget=\(budget) evaluated=\(s.evaluationCount) global=\(s.globalCount) score=\(s.top()[0].score) stop=\(s.reason)")
        return s
    }
    static func main() {
        // A low area limit must cover and refine every logarithmic area layer,
        // even when larger crops initially look more promising.
        for aspect in [1.5, 0.75] {
            var search = AdaptiveCropSearch(size:CGSize(width:4000,height:3000),aspect:aspect,area:0.1,budget:300)
            var coarseAreas: [Double] = [], refinedAreas: [Double] = []
            while let proposal = search.next() {
                let r = proposal.rect, area = r.width*r.height/12_000_000
                precondition(area >= 0.1 && r.maxX <= 4000 && r.maxY <= 3000 && r.minX >= 0 && r.minY >= 0)
                if proposal.phase == "粗搜覆盖" { coarseAreas.append(area) }
                if proposal.phase == "多路线细化" { refinedAreas.append(area) }
                // Constant scores ensure small-scale routes do not rely on winning globally.
                search.record(0.5)
            }
            let maxHeight = floor(min(3000,4000/aspect))
            let minHeight = ceil(sqrt(12_000_000*0.1/aspect))
            let layers = Int(ceil(log2(pow(maxHeight/minHeight,2))))
            for layer in 0..<layers {
                let lower = minHeight*pow(maxHeight/minHeight,Double(layer)/Double(layers))
                let upper = minHeight*pow(maxHeight/minHeight,Double(layer+1)/Double(layers))
                let lo = lower*lower*aspect/12_000_000, hi = upper*upper*aspect/12_000_000
                precondition(coarseAreas.filter { $0 >= lo-0.001 && $0 <= hi+0.001 }.count >= 10, "Area layer under-covered")
                precondition(refinedAreas.contains { $0 >= lo-0.001 && $0 <= hi+0.001 }, "Area layer never refined")
            }
            precondition(coarseAreas.min()! < 0.101, "Minimum area boundary missing")
            print("PASS 10% area limit, layered coverage and independent refinement: aspect=\(aspect)")
        }
        _ = run(30); _ = run(90,aspect:4.0/3)
        let deep = run(300); precondition(deep.evaluationCount > 90,"Budget does not expand actual search")
        let plateau = run(1000,constant:true);precondition(plateau.evaluationCount < 1000,"Plateau never converges")
        var single = AdaptiveCropSearch(size:CGSize(width:1000,height:1000),aspect:1,area:1,budget:300)
        precondition(single.next() != nil);single.record(0.5,countsAgainstBudget:false)
        precondition(single.next() == nil && single.evaluationCount == 0 && single.top().count == 1)
        print("PASS adaptive budget, coverage, portrait/landscape bounds, refinement, plateau stop, dedup and baseline reuse")
    }
}
