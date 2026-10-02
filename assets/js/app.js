// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/charger"
import topbar from "../vendor/topbar"

let mapLibrary = null

function loadStyle(href) {
  if (document.querySelector(`link[data-map-style="${href}"]`)) return Promise.resolve()

  return new Promise((resolve, reject) => {
    const link = document.createElement("link")
    link.rel = "stylesheet"
    link.href = href
    link.dataset.mapStyle = href
    link.onload = () => resolve()
    link.onerror = () => reject(new Error(href))
    document.head.append(link)
  })
}

function loadScript(src) {
  if (document.querySelector(`script[data-map-script="${src}"]`)) return Promise.resolve()

  return new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = src
    script.dataset.mapScript = src
    script.onload = () => resolve()
    script.onerror = () => reject(new Error(src))
    document.head.append(script)
  })
}

function mapStyleUrl() {
  const theme = document.documentElement.getAttribute("data-theme")
  const dark =
    theme === "dark" ||
    (theme !== "light" && window.matchMedia("(prefers-color-scheme: dark)").matches)

  return dark
    ? "https://tiles.openfreemap.org/styles/dark"
    : "https://tiles.openfreemap.org/styles/positron"
}

function ensureMapLibrary() {
  if (window.maplibregl) return Promise.resolve()

  mapLibrary ||= (async () => {
    await loadStyle("/vendor/maplibre-gl.css")
    await loadScript("/vendor/maplibre-gl.js")
  })()

  return mapLibrary
}

function mapPopup(point, linkLabel) {
  const root = document.createElement("div")
  root.className = "map-popup"
  const price = document.createElement("strong")
  price.textContent = point.price || ""
  const brand = document.createElement("div")
  brand.textContent = point.brand || ""
  const place = document.createElement("div")
  place.textContent = point.place || ""
  const link = document.createElement("a")
  link.href = point.href
  link.target = "_blank"
  link.rel = "noopener noreferrer"
  link.textContent = linkLabel || ""
  root.append(price, brand, place, link)
  return root
}

const Hooks = {
  StationMap: {
    mounted() {
      this.alive = true
      this.ready = false
      this.payload = null
      this.map = null
      this.popup = null
      this.refit = false
      this.styleUrl = null
      this.bound = false
      this.handleEvent("map-points", (payload) => {
        this.payload = payload
        this.draw(true)
      })
      this.onTheme = () => this.draw(false)
      window.addEventListener("phx:set-theme", this.onTheme)
      this.onScheme = () => this.draw(false)
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", this.onScheme)

      ensureMapLibrary().then(() => {
        if (!this.alive || !window.maplibregl) return
        this.createMap()
        this.ready = true
        this.draw(true)
      })
    },
    destroyed() {
      this.alive = false
      window.removeEventListener("phx:set-theme", this.onTheme)
      window.matchMedia("(prefers-color-scheme: dark)").removeEventListener("change", this.onScheme)
      if (this.map) this.map.remove()
      this.map = null
    },
    createMap() {
      const maplibregl = window.maplibregl
      this.styleUrl = mapStyleUrl()
      this.map = new maplibregl.Map({
        container: this.el,
        style: this.styleUrl,
        center: [-3.7, 40.2],
        zoom: 5,
        attributionControl: true
      })
      this.map.addControl(new maplibregl.NavigationControl({showCompass: false}), "top-left")
      this.popup = new maplibregl.Popup({offset: 12, closeButton: false, maxWidth: "260px"})
      this.map.on("load", () => this.paint())
      this.map.on("style.load", () => this.paint())
    },
    geojson() {
      return {
        type: "FeatureCollection",
        features: (this.payload.points || []).map((point) => ({
          type: "Feature",
          geometry: {type: "Point", coordinates: [point.lng, point.lat]},
          properties: {
            price: point.price || "",
            tier: point.tier || "same",
            brand: point.brand || "",
            place: point.place || "",
            href: point.href || ""
          }
        }))
      }
    },
    bind() {
      if (this.bound) return
      this.bound = true
      const canvas = () => this.map.getCanvas()

      this.map.on("click", "clusters", (event) => {
        const feature = event.features && event.features[0]
        if (!feature) return
        const source = this.map.getSource("stations")
        Promise.resolve(source.getClusterExpansionZoom(feature.properties.cluster_id)).then((zoom) => {
          this.map.easeTo({center: feature.geometry.coordinates, zoom})
        })
      })

      this.map.on("click", "points", (event) => {
        const feature = event.features && event.features[0]
        if (!feature || !this.payload) return
        this.popup
          .setLngLat(feature.geometry.coordinates)
          .setDOMContent(mapPopup(feature.properties, this.payload.link))
          .addTo(this.map)
      })

      for (const layer of ["clusters", "points"]) {
        this.map.on("mouseenter", layer, () => {
          canvas().style.cursor = "pointer"
        })
        this.map.on("mouseleave", layer, () => {
          canvas().style.cursor = ""
        })
      }
    },
    fit() {
      const points = (this.payload && this.payload.points) || []
      this.refit = false

      if (points.length === 0) {
        this.map.jumpTo({center: [-3.7, 40.2], zoom: 5})
        return
      }

      const bounds = new window.maplibregl.LngLatBounds()
      for (const point of points) bounds.extend([point.lng, point.lat])
      this.map.fitBounds(bounds, {padding: 40, maxZoom: 12, duration: 0})
    },
    paint() {
      if (!this.map || !this.payload) return

      if (!this.map.isStyleLoaded()) {
        this.map.once("idle", () => this.paint())
        return
      }

      this.map.resize()

      const data = this.geojson()

      if (this.map.getSource("stations")) {
        this.map.getSource("stations").setData(data)
      } else {
        this.map.addSource("stations", {
          type: "geojson",
          data,
          cluster: true,
          clusterRadius: 50,
          clusterMaxZoom: 14
        })
        this.map.addLayer({
          id: "clusters",
          type: "circle",
          source: "stations",
          filter: ["has", "point_count"],
          paint: {
            "circle-color": "#3DDC84",
            "circle-radius": ["step", ["get", "point_count"], 16, 20, 20, 80, 26],
            "circle-stroke-width": 2,
            "circle-stroke-color": "#083018"
          }
        })
        this.map.addLayer({
          id: "cluster-count",
          type: "symbol",
          source: "stations",
          filter: ["has", "point_count"],
          layout: {
            "text-field": ["get", "point_count_abbreviated"],
            "text-font": ["Noto Sans Regular"],
            "text-size": 12
          },
          paint: {"text-color": "#083018"}
        })
        this.map.addLayer({
          id: "points",
          type: "circle",
          source: "stations",
          filter: ["!", ["has", "point_count"]],
          paint: {
            "circle-color": "#3DDC84",
            "circle-radius": 7,
            "circle-stroke-width": 2,
            "circle-stroke-color": "#083018"
          }
        })
        this.bind()
      }

      if (this.refit) this.fit()
    },
    draw(refit) {
      if (!this.ready || !this.map || !this.payload) return
      if (refit) this.refit = true

      const nextStyle = mapStyleUrl()
      if (nextStyle !== this.styleUrl) {
        this.styleUrl = nextStyle
        this.map.setStyle(nextStyle)
        return
      }

      if (this.map.isStyleLoaded()) this.paint()
      requestAnimationFrame(() => {
        if (this.map) this.map.resize()
      })
    }
  },
  NearMe: {
    mounted() {
      this.el.addEventListener("click", (event) => {
        event.preventDefault()

        if (this.el.dataset.active === "true") {
          this.pushEvent("near_me", {clear: true})
          return
        }

        if (!navigator.geolocation) {
          this.pushEvent("near_me", {error: "unsupported"})
          return
        }

        this.el.disabled = true
        navigator.geolocation.getCurrentPosition(
          (position) => {
            this.el.disabled = false
            this.pushEvent("near_me", {
              lat: position.coords.latitude,
              lng: position.coords.longitude
            })
          },
          () => {
            this.el.disabled = false
            this.pushEvent("near_me", {error: "denied"})
          },
          {enableHighAccuracy: false, maximumAge: 60000, timeout: 10000}
        )
      })
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

