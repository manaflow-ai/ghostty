const fs = require('node:fs/promises')
const path = require('node:path')
const { once } = require('node:events')
const { app, BrowserWindow } = require('electron')
const ghostty = require('./build/Release/ghostty_embed.node')

const trace = (message) => console.error(`[electron-libghostty] ${message}`)
trace('main module loaded')

delete process.env.NO_COLOR

let window
let terminal
let diagnosticsTimer
const expectedRendererDeaths = new Set()
const artifacts = path.join(__dirname, 'artifacts')
const stressMode = process.argv.includes('--stress')
const integerArgument = (name, fallback) => {
  const argument = process.argv.find((value) => value.startsWith(`${name}=`))
  const parsed = Number.parseInt(argument?.split('=')[1], 10)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback
}
const stressIterations = integerArgument('--stress-iterations', 50)
const stressResizes = integerArgument('--stress-resizes', 50)
const stressRendererDeaths = integerArgument('--stress-renderer-deaths', 5)
const stressImmediateDestroys = integerArgument('--stress-immediate-destroys', 25)
const stressCycle = integerArgument('--stress-cycle', 0)
const diagnostics = {
  renderProcessGone: [],
  unexpectedRendererDeaths: [],
  unresponsive: [],
  native: [],
  memory: []
}

const terminalBounds = () => {
  const [width, height] = window.getContentSize()
  return {
    x: 16,
    y: 68,
    width: Math.max(360, Math.floor(width * 0.62) - 22),
    height: Math.max(260, height - 84)
  }
}

const nextTurn = () => new Promise((resolve) => setImmediate(resolve))

async function waitForNativeFrame(handle, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs
  let native
  do {
    native = ghostty.diagnostics(handle)
    if (native.rendererHealthy === false) {
      throw new Error(`libghostty renderer became unhealthy: ${JSON.stringify(native)}`)
    }
    if (native.swaps > 0n) return native
    await new Promise((resolve) => setTimeout(resolve, 10))
  } while (Date.now() < deadline)
  throw new Error(`libghostty produced no WGL frame within ${timeoutMs}ms`)
}

async function loadRenderer() {
  await window.loadFile(path.join(__dirname, 'renderer.html'))
}

async function publishDiagnostics() {
  if (!terminal || window.webContents.isDestroyed()) return
  const native = ghostty.diagnostics(terminal)
  const display = {
    ...native,
    swaps: native.swaps.toString(),
    electron: process.versions.electron,
    chrome: process.versions.chrome
  }
  diagnostics.native.push(display)
  await window.webContents.executeJavaScript(
    `document.querySelector('#status').textContent = ${JSON.stringify(JSON.stringify(display, null, 2))}`
  )
}

async function sampleMemory(iteration) {
  diagnostics.memory.push({
    iteration,
    browser: await process.getProcessMemoryInfo(),
    processes: app.getAppMetrics().map((metric) => ({
      pid: metric.pid,
      type: metric.type,
      memory: metric.memory
    }))
  })
}

function createTerminal() {
  trace('reading BrowserWindow native handle')
  const nativeHandle = window.getNativeWindowHandle()
  trace(`native handle acquired (${nativeHandle.length} bytes)`)
  const bounds = terminalBounds()
  trace(`creating terminal at ${JSON.stringify(bounds)}`)
  return ghostty.create(nativeHandle, {
    ...bounds,
    workingDirectory: process.cwd(),
    command: 'cmd.exe'
  })
}

async function crashAndRecoverRenderer(sequence) {
  const death = once(window.webContents, 'render-process-gone')
  expectedRendererDeaths.add(sequence)
  window.webContents.forcefullyCrashRenderer()
  await death
  await loadRenderer()
  if (terminal) ghostty.setBounds(terminal, terminalBounds())
  if (terminal) await waitForNativeFrame(terminal)
  await publishDiagnostics()
}

async function runStress() {
  await fs.mkdir(artifacts, { recursive: true })
  await sampleMemory(0)
  for (let immediate = 1; immediate <= stressImmediateDestroys; immediate += 1) {
    terminal = createTerminal()
    ghostty.destroy(terminal)
    terminal = undefined
    if (immediate % 5 === 0) await nextTurn()
  }
  let injectedRendererDeaths = 0
  for (let iteration = 1; iteration <= stressIterations; iteration += 1) {
    terminal = createTerminal()
    ghostty.sendText(
      terminal,
      `echo ghostty-stress-${stressCycle}-${iteration} & ` +
        'powershell.exe -NoProfile -Command "1..400 | ForEach-Object { Write-Output (\'row-{0:D4}\' -f $_) }"\r'
    )
    for (let resize = 0; resize < stressResizes; resize += 1) {
      const bounds = terminalBounds()
      ghostty.setBounds(terminal, {
        ...bounds,
        width: Math.max(360, bounds.width - ((resize * 17) % 220)),
        height: Math.max(260, bounds.height - ((resize * 13) % 180))
      })
      if (resize % 5 === 0) await nextTurn()
    }
    if (
      stressRendererDeaths > 0 &&
      injectedRendererDeaths < stressRendererDeaths &&
      iteration % Math.max(1, Math.floor(stressIterations / stressRendererDeaths)) === 0
    ) {
      injectedRendererDeaths += 1
      await crashAndRecoverRenderer(injectedRendererDeaths)
    }
    const native = await waitForNativeFrame(terminal)
    diagnostics.native.push({
      iteration,
      ...native,
      swaps: native.swaps.toString()
    })
    ghostty.destroy(terminal)
    terminal = undefined
    await nextTurn()
    if (iteration % 5 === 0 || iteration === stressIterations) {
      await sampleMemory(iteration)
    }
  }

  const totalWorkingSet = (sample) => sample.processes.reduce(
    (total, metric) => total + (metric.memory?.workingSetSize || 0),
    0
  )
  const first = diagnostics.memory.at(0)
  const last = diagnostics.memory.at(-1)
  const warmup = diagnostics.memory.find(
    (sample) => sample.iteration >= Math.min(10, stressIterations)
  ) || first
  const retainedGrowthAfterWarmupMB =
    (totalWorkingSet(last) - totalWorkingSet(warmup)) / 1024
  const peakGrowthAfterWarmupMB = (
    Math.max(...diagnostics.memory
      .filter((sample) => sample.iteration >= warmup.iteration)
      .map(totalWorkingSet)) - totalWorkingSet(warmup)
  ) / 1024
  const maxGrowthMB = Number.parseInt(
    process.env.GHOSTTY_STRESS_MAX_RETAINED_GROWTH_MB || '96',
    10
  )
  const nativeFailures = diagnostics.native.filter(
    (sample) => sample.rendererHealthy === false ||
      sample.realLibghostty === false ||
      BigInt(sample.swaps) === 0n
  )
  const report = {
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    cycle: stressCycle,
    immediateDestroys: stressImmediateDestroys,
    surfacesCreated: stressImmediateDestroys + stressIterations,
    iterations: stressIterations,
    resizesPerIteration: stressResizes,
    injectedRendererDeaths,
    retainedGrowthAfterWarmupMB,
    peakGrowthAfterWarmupMB,
    maxGrowthMB,
    diagnostics,
    pass: diagnostics.unexpectedRendererDeaths.length === 0 &&
      diagnostics.unresponsive.length === 0 &&
      nativeFailures.length === 0 &&
      retainedGrowthAfterWarmupMB <= maxGrowthMB &&
      peakGrowthAfterWarmupMB <= maxGrowthMB
  }
  await fs.writeFile(
    path.join(artifacts, `stress-${stressCycle}.json`),
    `${JSON.stringify(report, null, 2)}\n`
  )
  if (!report.pass) throw new Error(`Windows libghostty stress failed: ${JSON.stringify({
    unexpectedRendererDeaths: diagnostics.unexpectedRendererDeaths.length,
    unresponsive: diagnostics.unresponsive.length,
    nativeFailures: nativeFailures.length,
    retainedGrowthAfterWarmupMB,
    peakGrowthAfterWarmupMB
  })}`)
}

app.whenReady().then(async () => {
  trace('app ready')
  window = new BrowserWindow({
    width: 1280,
    height: 800,
    show: false,
    backgroundColor: '#090c10',
    webPreferences: {
      contextIsolation: true,
      sandbox: true
    }
  })
  trace('BrowserWindow created')

  window.webContents.on('render-process-gone', (_event, details) => {
    trace(`renderer gone: ${JSON.stringify(details)}`)
    diagnostics.renderProcessGone.push(details)
    if (expectedRendererDeaths.size > 0) {
      const first = expectedRendererDeaths.values().next().value
      expectedRendererDeaths.delete(first)
    } else {
      diagnostics.unexpectedRendererDeaths.push(details)
    }
  })
  window.on('unresponsive', () => {
    trace('BrowserWindow unresponsive')
    diagnostics.unresponsive.push({ time: new Date().toISOString() })
  })

  const readyToShow = once(window, 'ready-to-show')
  await Promise.all([loadRenderer().then(() => trace('renderer document loaded')), readyToShow])
  trace('ready-to-show received')
  terminal = createTerminal()
  trace('native terminal created')
  window.show()
  ghostty.focus(terminal)
  if (!stressMode) {
    await publishDiagnostics()
    diagnosticsTimer = setInterval(() => {
      publishDiagnostics().catch((error) => trace(`diagnostics failed: ${error}`))
    }, 1000)
  }

  window.on('resize', () => {
    if (terminal) ghostty.setBounds(terminal, terminalBounds())
  })
  // Tear down while Electron's parent HWND and the child's HDC are valid.
  // The later `closed` event is too late because Chromium has destroyed the
  // native parent by then.
  window.on('close', () => {
    trace('BrowserWindow close')
    clearInterval(diagnosticsTimer)
    diagnosticsTimer = undefined
    if (terminal) ghostty.destroy(terminal)
    terminal = undefined
  })
  window.on('closed', () => {
    trace('BrowserWindow closed')
    window = undefined
  })

  if (stressMode) {
    ghostty.destroy(terminal)
    terminal = undefined
    await runStress()
    app.exit(0)
  }
}).catch((error) => {
  console.error(error)
  app.exit(1)
})

app.on('window-all-closed', () => app.quit())
app.on('child-process-gone', (_event, details) => {
  trace(`child process gone: ${JSON.stringify(details)}`)
})
app.on('before-quit', () => trace('app before-quit'))
app.on('will-quit', () => trace('app will-quit'))
