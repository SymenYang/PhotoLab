import Foundation

enum ArtScoring {
    // Fixed monotone cubic Hermite curve (PCHIP); version 2.
    static let x: [Double] = [0,20,40,50,60,70,80,90,100]
    static let y: [Double] = [0,0.4,1.5,2.2,3.1,4.2,4.9,4.97,5]
    static let slopes: [Double] = {
        let h = zip(x.dropFirst(), x).map(-)
        let d = zip(y.dropFirst(), y).enumerated().map { ($0.element.0 - $0.element.1) / h[$0.offset] }
        var m = Array(repeating: 0.0, count: x.count)
        for i in 1..<(x.count - 1) {
            let w1 = 2*h[i] + h[i-1], w2 = h[i] + 2*h[i-1]
            m[i] = (w1+w2)/(w1/d[i-1]+w2/d[i])
        }
        m[0] = max(0, min(3*d[0], ((2*h[0]+h[1])*d[0]-h[0]*d[1])/(h[0]+h[1])))
        let n = d.count-1
        m[m.count-1] = max(0,min(3*d[n],((2*h[n]+h[n-1])*d[n]-h[n]*d[n-1])/(h[n]+h[n-1])))
        return m
    }()
    static func display(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        let value = min(100,max(0,raw*100))
        let i = min(x.count-2, max(0, (x.firstIndex { $0 > value } ?? (x.count-1))-1))
        let h = x[i+1]-x[i], t = (value-x[i])/h
        return (2*t*t*t-3*t*t+1)*y[i] + (t*t*t-2*t*t+t)*h*slopes[i]
            + (-2*t*t*t+3*t*t)*y[i+1] + (t*t*t-t*t)*h*slopes[i+1]
    }
}
