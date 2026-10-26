import Foundation
@main struct ArtScoringTests {
    static func main() throws {
        var previous = -1.0
        for i in 0...10000 {
            let value = ArtScoring.display(Double(i)/10000)
            precondition(value >= previous && value >= 0 && value <= 5, "Curve must cover 0–5 monotonically")
            previous = value
        }
        for (x,y) in zip(ArtScoring.x,ArtScoring.y) { precondition(abs(ArtScoring.display(x/100)-y) < 1e-10) }
        precondition(abs(ArtScoring.display(0.4)-1.5)<1e-10 && abs(ArtScoring.display(0.8)-4.9)<1e-10)
        precondition(ArtScoring.display(0)==0 && ArtScoring.display(1)==5)
        let a = Asset(id:"a",rootID:"root",folder:"",name:"a",video:false,files:[MediaFile(relativePath:"a.jpg",size:100,modified:1)],date:1)
        var b=a;b.id="b";b.name="b";b.captureDate=20
        var c=a;c.id="c";c.name="c";c.captureDate=40
        var f=FilterState();f.sort="artHigh"
        precondition(LibraryQuery.run([a,b,c],filter:f,dates:false,semantic:nil,artScores:["a":0.8,"b":0.3]).map(\.id)==["a","b","c"])
        f.sort="artLow"
        precondition(LibraryQuery.run([a,b,c],filter:f,dates:false,semantic:nil,artScores:["a":0.8,"b":0.3]).map(\.id)==["b","a","c"])
        for sort in ["qualityHigh","qualityLow"] {
            f.sort=sort
            let expected = sort == "qualityHigh" ? ["a","b","c"] : ["b","a","c"]
            precondition(LibraryQuery.run([a,b,c],filter:f,dates:false,semantic:nil,artScores:["a":0.8,"b":0.3]).map(\.id)==expected)
        }
        var dayA = a; dayA.captureDate = 1700000000
        var dayB = b; dayB.captureDate = 1700000010
        var dayC = c; dayC.captureDate = 1700000000 + 86400
        for sort in ["artHigh","artLow","qualityHigh","qualityLow","rating"] {
            f.sort = sort
            dayA.rating = 5; dayB.rating = 1
            let high = sort == "artHigh" || sort == "qualityHigh" || sort == "rating"
            let ids = LibraryQuery.run([dayA,dayB,dayC],filter:f,dates:true,semantic:nil,artScores:["a":0.8,"b":0.3]).map(\.id)
            precondition(ids == (high ? ["c","a","b"] : ["c","b","a"]), "Date group precedes score; time within day must not override score")
        }
        precondition(LibraryQuery.run([dayA,dayB,dayC],filter:f,dates:true,semantic:["b","a","c"]).map(\.id)==["c","b","a"])
        let sections = [0..<5,5..<12]
        precondition(GridNavigation.target(current:2,columns:3,direction:1,sections:sections)==4)
        precondition(GridNavigation.target(current:4,columns:3,direction:1,sections:sections)==6)
        precondition(GridNavigation.target(current:7,columns:3,direction:-1,sections:sections)==4)
        precondition(GridNavigation.target(current:0,columns:3,direction:-1,sections:sections)==0)
        precondition(GridNavigation.target(current:11,columns:3,direction:1,sections:sections)==11)
        precondition(GridNavigation.target(current:3,columns:2,direction:1,sections:[0..<400])==5)
        precondition(GridNavigation.target(current:299,columns:3,direction:1,sections:[0..<400])==302)
        var rotated=a;rotated.rotation=1;precondition(a.artFingerprint != rotated.artFingerprint)
        precondition(a.qualityFingerprint != rotated.qualityFingerprint && a.qualityFingerprint != a.artFingerprint)
        var moved=a;moved.files[0].relativePath="child/a.jpg";moved.identityPaths=["child/a.jpg":"a.jpg"]
        precondition(a.artFingerprint == moved.artFingerprint)
        f=FilterState();f.rootID="root";f.folder="trip";f.recursive=true
        var d=a;d.folder="trip/day";precondition(f.matches(d));f.recursive=false;precondition(!f.matches(d))
        print("PASS: mapping, ordering, missing scores, rotation, root merge identity, recursive scope")
    }
}
