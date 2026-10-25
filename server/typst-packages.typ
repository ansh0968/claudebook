// Shipped package versions. Keep this file as the single Docker/CI warm-up.
// Verified typst.toml compiler floors: cetz/cetz-plot/chemformula 0.13.1,
// physica 0.13.0. No compiler upgrade from Typst 0.13.1 is needed.
// Compatibility versions cetz 0.3.2 and cetz-plot 0.1.1 both require only 0.12.0.
#import "@preview/cetz:0.4.0": canvas, draw
#import "@preview/cetz-plot:0.1.2": plot
#import "@preview/physica:0.9.6" as physica
#import "@preview/chemformula:0.1.2": ch
#import "@preview/cetz:0.3.2" as cetz032 // offline-compat
#import "@preview/cetz-plot:0.1.1" as cetzPlot011 // offline-compat

#set page(width: 14cm, height: auto, margin: 1cm)
#canvas({
  draw.line((0, 0), (2, 1))
  draw.circle((1, 1), radius: 0.4)
})
#canvas({
  plot.plot(size: (4, 3), x-tick-step: none, y-tick-step: none, {
    plot.add(((0, 0), (1, 1), (2, 4)))
  })
})
#ch("H2O + CO2 -> H2CO3")
#physica.dv($f$, $x$)

// Exercise the compatibility canvas and plot, including their transitive imports.
#cetz032.canvas({
  cetz032.draw.line((0, 0), (2, 1))
  cetz032.draw.circle((1, 1), radius: 0.4)
  cetzPlot011.plot.plot(size: (4, 3), x-tick-step: none, y-tick-step: none, {
    cetzPlot011.plot.add(((0, 0), (1, 1), (2, 4)))
  })
})


