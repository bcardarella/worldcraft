import Foundation

// Offline authoring only. No Audio Units, audio device, network service or
// synthesizer runs in the app. All instruments and effects below are original.
struct Note: Decodable {
  let t, length, pitch, gain, pan: Double
  let voice: String
}
struct Render: Decodable {
  let id: String
  let seconds: Double
  let stereo, loop: Bool
  let room: Double
  let seed: UInt64
  let notes: [Note]
}
struct Oscillator {
  var x: Double = 0
  var y: Double = 1
  let c, s, damping, gain: Double
  init(hz: Double, decay: Double, gain: Double) {
    let w = 2 * Double.pi * hz / 48000
    c = cos(w); s = sin(w); damping = exp(-decay / 48000); self.gain = gain
  }
  mutating func next() -> Double {
    let nx = (x * c + y * s) * damping
    y = (y * c - x * s) * damping; x = nx
    return x * gain
  }
}
struct RNG {
  var value: UInt64
  mutating func noise() -> Double {
    value = value &* 6364136223846793005 &+ 1442695040888963407
    return Double(value >> 32) / Double(UInt32.max) * 2 - 1
  }
}
@main enum RenderAudio {
  static let rate = 48000
  static func main() throws {
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let renders = try JSONDecoder().decode([Render].self, from: Data(contentsOf: input))
    for render in renders {
      let n = Int((render.seconds * Double(rate)).rounded())
      let tail = render.stereo ? rate * 8 : rate / 2
      var left = [Float](repeating: 0, count: n + tail)
      var right = left
      var rng = RNG(value: render.seed)
      for note in render.notes {
        add(note, rng: &rng, left: &left, right: &right)
      }
      if render.room > 0 { room(&left, &right, amount: render.room) }
      if render.loop {
        for i in 0..<min(tail, n) {
          left[i] += left[n + i]; right[i] += right[n + i]
        }
        // Periodic loop boundary, with an inaudibly short smooth correction.
        let count = min(192, n)
        let dl = left[n-1] - left[0], dr = right[n-1] - right[0]
        for i in 0..<count {
          let t = Float(i) / Float(count)
          let blend = (1-t)*(1-t)*(1+2*t)
          left[i] += dl*blend; right[i] += dr*blend
        }
      } else {
        for i in 0..<min(n, 480) {
          let gain = Float(i) / 480
          left[i] *= gain; right[i] *= gain
          left[n-1-i] *= gain; right[n-1-i] *= gain
        }
      }
      left.removeSubrange(n...); right.removeSubrange(n...)
      let peak = zip(left, right).reduce(Float(0)) { max($0, abs($1.0), abs($1.1)) }
      let gain: Float = peak > 0 ? 0.72 / peak : 0
      var pcm = [Int16](); pcm.reserveCapacity(n * (render.stereo ? 2 : 1))
      for i in 0..<n {
        pcm.append(Int16(max(-32760, min(32760, left[i] * gain * 32767))))
        if render.stereo { pcm.append(Int16(max(-32760, min(32760, right[i] * gain * 32767)))) }
      }
      try write(pcm, channels: render.stereo ? 2 : 1, to: output.appendingPathComponent(render.id + ".wav"))
      print("Rendered \(render.id) · \(String(format: "%.1f",render.seconds))s")
      fflush(stdout)
    }
  }
  static func add(_ note: Note, rng: inout RNG, left: inout [Float], right: inout [Float]) {
    let first = max(0, Int(note.t * Double(rate)))
    let length = max(0.01, note.length)
    let count = min(Int(length * Double(rate)), left.count-first)
    guard count > 0 else { return }
    let frequency = 440 * pow(2, (note.pitch-69)/12)
    let pan = min(1, max(0, note.pan))
    let gl = note.gain * cos(pan * .pi/2), gr = note.gain * sin(pan * .pi/2)
    var partials: [Oscillator] = []
    var attack = 0.008, release = min(0.12, length*0.22)
    var air = 0.0, lp = 0.0, slow = 0.0, phase = 0.0
    switch note.voice {
    case "piano", "felt":
      let felt = note.voice == "felt"
      for k in 1...8 {
        let ratio = Double(k) * sqrt(1 + 0.00022 * Double(k*k))
        partials.append(.init(hz: frequency*ratio, decay: (felt ? 0.65 : 0.45)+Double(k)*0.24,
          gain: pow(Double(k), felt ? -2.15 : -1.55)))
      }
      air = 0.018; release = min(0.55,length*0.22)
    case "pluck", "harp":
      for k in 1...6 { partials.append(.init(hz:frequency*Double(k), decay:0.7+Double(k)*0.5,
        gain: sin(Double(k)*0.82)/pow(Double(k),1.25))) }
      air = 0.025; attack = 0.003
    case "bell", "vibes":
      for (i,ratio) in [1.0,2.01,2.76,5.4,8.9].enumerated() {
        partials.append(.init(hz: frequency*ratio, decay:0.6+Double(i)*0.6, gain:pow(0.35,Double(i))))
      }
      attack = 0.003; release = min(0.7,length*0.3)
    case "pad", "strings":
      for (i,ratio) in [0.998,1.002,2.001,3.002,4.0].enumerated() {
        partials.append(.init(hz:frequency*ratio,decay:0,gain:pow(0.4,Double(max(0,i-1)))))
      }
      attack = min(1.4,length*0.25); release = min(2.0,length*0.3)
    case "flute":
      for (i,ratio) in [1.0,2.0,3.0].enumerated() { partials.append(.init(hz:frequency*ratio,decay:0.12,gain:pow(0.18,Double(i)))) }
      attack=0.1; release=min(0.4,length*0.25); air=0.025
    case "bass":
      for k in 1...4 { partials.append(.init(hz:frequency*Double(k),decay:1.8+Double(k),gain:1/pow(Double(k),2))) }
      attack=0.012
    case "impact":
      for (i,ratio) in [1.0,1.43,2.21,3.7,5.1].enumerated() { partials.append(.init(hz:frequency*ratio,decay:8+Double(i)*4,gain:pow(0.48,Double(i)))) }
      air=0.38; attack=0.001; release=min(0.05,length*0.2)
    default: break
    }
    for i in 0..<count {
      let t = Double(i)/Double(rate), progress=t/length
      let random = rng.noise()
      lp += (random-lp)*0.08; slow += (random-slow)*0.008
      var sample=0.0
      for p in partials.indices { sample += partials[p].next() }
      sample += air*(random-lp)*exp(-t*90)
      switch note.voice {
      case "noise", "rustle", "sand", "snow":
        let brightness = note.voice == "sand" ? 0.35 : note.voice == "snow" ? 0.13 : 0.7
        let grain = 0.35 + 0.65*pow(max(0,sin(t*75 + sin(t*17)*3)),2)
        sample=(lp+(random-lp)*brightness)*grain*exp(-progress*5)
      case "wind", "rain", "river", "ocean", "lava", "underwater", "cave", "fire", "lake":
        let swell=0.66+0.22*sin(t*0.51)+0.12*sin(t*1.43)
        if note.voice == "fire" { sample=lp*0.35+random*pow(max(0,sin(t*11+sin(t*23)*4)),18)*0.4 }
        if note.voice == "lake" { sample=slow*0.5+lp*0.18*(0.6+0.4*sin(t*2.1)) }
        if note.voice == "wind" { sample=(slow*2 + lp*0.14)*swell }
        if note.voice == "rain" { sample=(random*0.18+lp*0.65)*swell }
        if note.voice == "river" { sample=(lp*1.1+random*0.13)*swell }
        if note.voice == "ocean" { sample=(lp+random*0.14)*(0.28+0.72*pow(0.5+0.5*sin(t*0.63),2)) }
        if note.voice == "lava" { sample=slow*2+sin(t*2 * .pi*43)*0.05*swell }
        if note.voice == "underwater" { sample=slow*1.5+sin(t*2 * .pi*67)*0.022*swell }
        if note.voice == "cave" { sample=slow*0.7+sin(t*2 * .pi*51)*0.016 }
        attack=0.04; release=0.04
      case "bubble":
        phase += 2 * .pi*frequency*(1+progress*1.8)/Double(rate)
        sample=sin(phase)*exp(-t*18)+lp*0.3*exp(-t*25)
      case "engine":
        phase += 2 * .pi*frequency/Double(rate)
        let pulse=sin(phase)+0.35*sin(phase*2)+0.18*sin(phase*4)
        sample=pulse*(0.65+0.35*sin(t*2 * .pi*11))+lp*0.4
        attack=0.03; release=0.03
      case "horn":
        // Slightly detuned automotive reeds, with rounded attack/release and
        // saturated harmonics rather than a brittle square-wave beep.
        phase += 2 * .pi*frequency*(1+0.0015*sin(t*27))/Double(rate)
        sample=tanh((sin(phase)+0.40*sin(phase*2)+0.21*sin(phase*3))*1.5)*0.65
          + sin(phase*1.003)*0.15 + lp*0.02
        attack=0.025; release=0.08
      case "voice":
        let contour=1+0.13*sin(progress * .pi*2)+0.035*sin(t*2 * .pi*19)
        phase += 2 * .pi*frequency*contour/Double(rate)
        sample=(sin(phase)+0.48*sin(phase*2)+0.18*sin(phase*3)+lp*0.7)
          * pow(max(0,sin(progress * .pi)),0.8)*(0.75+0.25*sin(t*31))
        attack=0.015; release=0.03
      case "breath":
        sample=lp*(0.6+0.4*sin(t*frequency*0.02))*sin(progress * .pi)
      case "growl":
        phase += 2 * .pi*frequency*(1-progress*0.35)/Double(rate)
        sample=(sin(phase)+0.4*sin(phase*1.99)+lp*2.2)*(0.65+0.35*sin(t*47))*sin(progress * .pi)
      case "chirp":
        phase += 2 * .pi*frequency*(1+progress*0.4+0.07*sin(t*60))/Double(rate)
        sample=(sin(phase)+0.12*sin(phase*2))*pow(sin(progress * .pi),2)
      case "kick":
        phase += 2 * .pi*(42+85*exp(-t*35))/Double(rate)
        sample=sin(phase)*exp(-t*10)+random*0.035*exp(-t*150)
        attack=0.001
      case "snare":
        sample=(random-lp)*exp(-t*24)*0.7+sin(t*2 * .pi*185)*exp(-t*30)*0.3
        attack=0.001
      case "hat":
        sample=(random-lp)*exp(-t*65)*0.5
        attack=0.001
      default: break
      }
      let a=min(1,t/max(0.0001,attack)), r=min(1,(length-t)/max(0.0001,release))
      sample *= a*r
      left[first+i] += Float(sample*gl)
      right[first+i] += Float(sample*gr)
    }
  }
  static func room(_ left: inout [Float], _ right: inout [Float], amount: Double) {
    // Parallel damped combs and cross-channel early reflections. Delays are
    // mutually prime to avoid metallic ringing in the quiet piano pieces.
    let delays=[1423,1789,2137,2593,2939,3251]
    let dryL=left,dryR=right
    for (voice,delay) in delays.enumerated() {
      var line=[Float](repeating:0,count:delay),filter:Float=0
      for i in left.indices {
        let j=i%delay,wet=line[j]
        filter += (wet-filter)*0.42
        line[j]=(voice%2==0 ? dryL[i]:dryR[i])*0.27+filter*0.73
        if voice%2==0 {left[i] += wet*Float(amount);right[i] += wet*Float(amount*0.26)}
        else {right[i] += wet*Float(amount);left[i] += wet*Float(amount*0.26)}
      }
    }
  }
  static func write(_ samples:[Int16],channels:Int,to url:URL) throws {
    var data=Data()
    func text(_ s:String) { data.append(contentsOf:s.utf8) }
    func u16(_ n:UInt16) { var n=n.littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)} }
    func u32(_ n:UInt32) { var n=n.littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)} }
    text("RIFF");u32(UInt32(36+samples.count*2));text("WAVEfmt ");u32(16)
    u16(1);u16(UInt16(channels));u32(UInt32(rate));u32(UInt32(rate*channels*2));u16(UInt16(channels*2));u16(16)
    text("data");u32(UInt32(samples.count*2))
    samples.withUnsafeBytes { data.append(contentsOf:$0) }
    try data.write(to:url)
  }
}
