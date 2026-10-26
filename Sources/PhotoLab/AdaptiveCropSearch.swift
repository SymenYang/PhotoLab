import Foundation
import CoreGraphics

struct CropSearchProposal {
    let rect: CGRect
    let phase: String
}
struct CropSearchSample {
    let id: Int
    let rect: CGRect
    let score: Double
}
// Geometry and budget policy are independent of image rendering and model inference.
struct AdaptiveCropSearch {
    let size: CGSize
    let aspect: Double
    let area: Double
    let budget: Int
    private(set) var samples: [CropSearchSample] = []
    private(set) var reason = "预算已用完"
    private(set) var globalCount = 0
    private(set) var evaluationCount = 0
    private var seen: [String:Int] = [:]
    private var pool: [CGRect] = []
    private var distances: [Double] = []
    private var routes: [Route] = []
    private var pendingRoute: Int?
    private var pendingGlobal = false
    private var lastImprovement = 0
    private var bands: [(Double,Double)] = []
    private var poolBands: [Int] = []
    private var coverage: [Int] = []
    private var quotas: [Int] = []
    private var bestScore = -Double.infinity
    private var lastReseed = -1
    private var proposal: CropSearchProposal?
    private struct Route {
        var band: Int
        var center: CropSearchSample
        var best: CropSearchSample
        var step = 0.16
        var cursor = 0
        var direction = 0
        var nextDirection = 0
        var gain = 0.0
        var lastUsed = 0
        var active: Bool { step >= 0.01 }
    }
    private var routesPerBand: Int { budget >= bands.count*100 ? 2 : 1 }
    private var routeCount: Int { bands.count*routesPerBand }
    private var directionCount: Int { budget >= 180 ? 14 : 6 }
    private var coarseCount: Int { max(6, Int(Double(budget)*0.4)) }
    private var minHeight: Double { ceil(sqrt(size.width*size.height*area/aspect)) }
    private var maxHeight: Double { floor(min(size.height,size.width/aspect)) }
    init(size: CGSize, aspect: Double, area: Double, budget: Int) {
        self.size = size; self.aspect = aspect; self.area = area; self.budget = max(1,budget)
        var keys = Set<String>()
        func radical(_ value: Int, _ base: Int) -> Double {
            var n = value, f = 1.0, result = 0.0
            while n > 0 { f /= Double(base); result += f*Double(n % base); n /= base }
            return result
        }
        let lo = min(minHeight,maxHeight), hi = maxHeight
        let minimum = lo*lo*aspect, maximum = hi*hi*aspect
        let desired = max(1,Int(ceil(log2(max(1,maximum/minimum)))))
        let count = min(desired,max(1,coarseCount/6))
        for i in 0..<count {
            bands.append((lo*pow(hi/lo,Double(i)/Double(count)),lo*pow(hi/lo,Double(i+1)/Double(count))))
        }
        coverage = Array(repeating:0,count:count)
        quotas = Array(repeating:coarseCount/count,count:count)
        // A bounded small-scale preference: at most twice the largest band's weight.
        let weights = (0..<count).map { 1.0+Double(count-1-$0)/Double(max(1,count-1)) }
        let total = weights.reduce(0,+)
        quotas = weights.map { max(3,Int(Double(coarseCount)*$0/total)) }
        while quotas.reduce(0,+) < coarseCount { quotas[quotas.reduce(0,+)%count] += 1 }
        while quotas.reduce(0,+) > coarseCount {
            if let i = quotas.indices.max(by:{ quotas[$0]<quotas[$1] }), quotas[i]>1 { quotas[i] -= 1 }
        }
        for band in bands.indices {
            var positions: [(Double,Double,Double)] = []
            for scale in [0.0,1.0,0.5] { for y in [0.5,0.0,1.0] { for x in [0.5,0.0,1.0] { positions.append((x,y,scale)) } } }
            for i in 1...max(128,self.budget*8/count) { positions.append((radical(i,2),radical(i,3),radical(i,5))) }
            for (x,y,scale) in positions {
                let h = bands[band].0*pow(bands[band].1/bands[band].0,scale), w = ceil(h*aspect)
                let r = box(w/2+x*(size.width-w),h/2+y*(size.height-h),h)
                if keys.insert(key(r)).inserted { pool.append(r); poolBands.append(band) }
            }
        }
        distances = Array(repeating: Double.infinity,count: pool.count)
    }
    private func key(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }
    private func box(_ cx: Double, _ cy: Double, _ height: Double) -> CGRect {
        let h = min(maxHeight,max(minHeight,height.rounded())), w = min(size.width,ceil(h*aspect))
        return CGRect(x: min(size.width-w,max(0,(cx-w/2).rounded())),y: min(size.height-h,max(0,(cy-h/2).rounded())),width:w,height:h)
    }
    private func distance(_ a: CGRect,_ b: CGRect) -> Double {
        pow((a.midX-b.midX)/sqrt(a.width*b.width),2)+pow((a.midY-b.midY)/sqrt(a.height*b.height),2)+pow(log(a.height/b.height),2)
    }
    private func overlap(_ a: CGRect,_ b: CGRect) -> Double {
        let i = a.intersection(b), v = i.isNull ? 0 : i.width*i.height
        return v/(a.width*a.height+b.width*b.height-v)
    }
    func top(_ count: Int = 5, fill: Bool = true) -> [CropSearchSample] {
        let ranked = samples.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var best: [CropSearchSample] = []
        for s in ranked where best.allSatisfy({ overlap($0.rect,s.rect)<0.85 }) {
            best.append(s); if best.count == count { break }
        }
        if fill && best.count < count {
            for s in ranked where !best.contains(where: { $0.id == s.id }) { best.append(s); if best.count == count { break } }
        }
        return best.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }
    private func bandOf(_ rect: CGRect) -> Int {
        bands.indices.first(where:{ rect.height < bands[$0].1 }) ?? bands.count-1
    }
    private mutating func reseed() {
        for band in bands.indices {
            let ranked = samples.filter { bandOf($0.rect) == band }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            var seeds: [CropSearchSample] = []
            for sample in ranked where seeds.allSatisfy({ overlap($0.rect,sample.rect)<0.85 }) {
                seeds.append(sample); if seeds.count == routesPerBand { break }
            }
            for seed in seeds {
                if let i = routes.indices.first(where:{ routes[$0].band == band && overlap(routes[$0].best.rect,seed.rect)>=0.85 }) {
                    if seed.score > routes[i].best.score {
                        routes[i].center = seed; routes[i].best = seed; routes[i].cursor = 0
                        routes[i].step = max(0.04,routes[i].step)
                    }
                } else if routes.filter({$0.band == band}).count < routesPerBand {
                    routes.append(Route(band:band,center:seed,best:seed,lastUsed:samples.count))
                } else if let i = routes.indices.filter({ routes[$0].band == band && !routes[$0].active }).min(by:{ routes[$0].best.score < routes[$1].best.score }), seed.score > routes[i].best.score {
                    routes[i] = Route(band:band,center:seed,best:seed,lastUsed:samples.count)
                }
            }
        }
        lastReseed = samples.count
    }
    private mutating func global() -> CGRect? {
        // Coverage quotas precede score-based competition; later exploration favours
        // under-sampled layers without eliminating any layer.
        let ordered = bands.indices.sorted {
            let a = Double(coverage[$0])/Double(quotas[$0]), b = Double(coverage[$1])/Double(quotas[$1])
            return a == b ? $0 < $1 : a < b
        }
        for band in ordered {
            var index: Int?
            for i in pool.indices where poolBands[i] == band && seen[key(pool[i])] == nil && distances[i] > 0.000009 {
                if index == nil || distances[i] > distances[index!] { index = i }
            }
            guard let i = index else { continue }
            let r = pool[i]; coverage[band] += 1
            for j in pool.indices { distances[j] = min(distances[j],distance(r,pool[j])) }
            return r
        }
        return nil
    }
    private mutating func local(_ index: Int) -> CGRect? {
        // A cached neighbor still informs refinement, but consumes no model budget.
        for _ in 0..<100 {
            guard routes[index].active else { return nil }
            if routes[index].cursor == directionCount {
                let gain = routes[index].best.score-routes[index].center.score
                routes[index].gain = max(0,gain)
                if gain > 0 { routes[index].center = routes[index].best; routes[index].direction = routes[index].nextDirection }
                else { routes[index].step /= 2 }
                routes[index].cursor = 0
                continue
            }
            let direction = (routes[index].direction+routes[index].cursor)%directionCount
            routes[index].cursor += 1
            let c = routes[index].center.rect, step = routes[index].step
            let dx = step*c.width, dy = step*c.height
            let changes: [(Double,Double,Double)] = [(-dx,0,0),(dx,0,0),(0,-dy,0),(0,dy,0),(0,0,-1),(0,0,1),(-dx,-dy,0),(dx,-dy,0),(-dx,dy,0),(dx,dy,0),(-dx/2,-dy/2,-1),(dx/2,dy/2,-1),(-dx/2,-dy/2,1),(dx/2,dy/2,1)]
            let (x,y,scale) = changes[direction]
            let r = box(c.midX+x,c.midY+y,c.height*pow(1+step,scale))
            if let id = seen[key(r)] {
                if samples[id].score > routes[index].best.score { routes[index].best = samples[id]; routes[index].nextDirection = direction }
                continue
            }
            return r
        }
        return nil
    }
    mutating func next() -> CropSearchProposal? {
        precondition(proposal == nil,"Score the pending proposal first")
        guard evaluationCount < budget else { reason = "预算已用完"; return nil }
        if samples.count >= coarseCount && (routes.isEmpty || samples.count-lastReseed >= 10) { reseed() }
        pendingRoute = nil; pendingGlobal = false
        let coarse = samples.count < coarseCount
        // After initial coverage reserve one in three decisions for new compositions.
        let explore = coarse || (samples.count-coarseCount)%3 == 0 || routes.allSatisfy({ !$0.active })
        if !coarse && routes.allSatisfy({ !$0.active }) && coverage.indices.allSatisfy({ coverage[$0] >= quotas[$0] }) && samples.count-lastImprovement >= max(20,routeCount*directionCount) {
            reason = "各路线已细化，近期未发现更高分方案"; return nil
        }
        if explore, let r = global() {
            pendingGlobal = true; proposal = CropSearchProposal(rect:r,phase:coarse ? "粗搜覆盖" : "探索新构图"); return proposal
        }
        if !coarse {
            let ordered = routes.indices.filter { routes[$0].active }.sorted {
                let a = min(0.05,routes[$0].gain)+routes[$0].best.score*0.01+Double(samples.count-routes[$0].lastUsed)*0.002
                let b = min(0.05,routes[$1].gain)+routes[$1].best.score*0.01+Double(samples.count-routes[$1].lastUsed)*0.002
                return a == b ? $0 < $1 : a > b
            }
            for i in ordered { if let r = local(i) { pendingRoute = i; proposal = CropSearchProposal(rect:r,phase:"多路线细化"); return proposal } }
        }
        if let r = global() { pendingGlobal = true; proposal = CropSearchProposal(rect:r,phase:"探索新构图"); return proposal }
        if coarse && !samples.isEmpty { reseed(); for i in routes.indices { if let r = local(i) { pendingRoute = i; proposal = CropSearchProposal(rect:r,phase:"多路线细化"); return proposal } } }
        reason = "可用的不同裁剪已搜索完成"; return nil
    }
    mutating func record(_ score: Double, countsAgainstBudget: Bool = true) {
        if countsAgainstBudget { evaluationCount += 1 }
        precondition(score.isFinite && proposal != nil)
        let sample = CropSearchSample(id:samples.count,rect:proposal!.rect,score:score)
        let previousTop = top().map(\.score).reduce(0,+)
        seen[key(sample.rect)] = sample.id; samples.append(sample)
        if top().map(\.score).reduce(0,+) > previousTop+0.00001 { lastImprovement = samples.count }
        if score > bestScore { bestScore = score; lastImprovement = samples.count }
        if pendingGlobal { globalCount += 1 }
        if let i = pendingRoute {
            routes[i].lastUsed = samples.count
            if score > routes[i].best.score {
                routes[i].best = sample; routes[i].nextDirection = (routes[i].direction+routes[i].cursor-1)%directionCount
                routes[i].gain = max(routes[i].gain,score-routes[i].center.score)
            }
        }
        proposal = nil
    }
}
