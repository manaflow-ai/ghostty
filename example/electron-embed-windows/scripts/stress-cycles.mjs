import { spawn } from 'node:child_process'
import fs from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'

const root = path.resolve(import.meta.dirname, '..')
const artifacts = path.join(root, 'artifacts')
const electron = path.join(root, 'node_modules', 'electron', 'dist', 'electron.exe')
const mesaOpenGl = path.join(root, 'build', 'Release', 'opengl32.mesa.dll')
const mesaGallium = path.join(root, 'build', 'Release', 'libgallium_wgl.dll')
const integerArgument = (name, fallback) => {
  const argument = process.argv.find((value) => value.startsWith(`${name}=`))
  const parsed = Number.parseInt(argument?.split('=')[1], 10)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback
}
const cycles = integerArgument('--cycles', 5)
const iterations = integerArgument('--iterations', 50)
const resizes = integerArgument('--resizes', 50)
const rendererDeaths = integerArgument('--renderer-deaths', 5)
const immediateDestroys = integerArgument('--immediate-destroys', 25)
const timeoutMs = integerArgument('--timeout-ms', 240000)

await fs.mkdir(artifacts, { recursive: true })
const childEnvironment = { ...process.env, NO_COLOR: '' }
try {
  await Promise.all([fs.access(mesaOpenGl), fs.access(mesaGallium)])
  childEnvironment.GHOSTTY_MESA_OPENGL_PATH ||= mesaOpenGl
  childEnvironment.GALLIUM_DRIVER ||= 'llvmpipe'
  childEnvironment.LIBGL_ALWAYS_SOFTWARE ||= 'true'
  childEnvironment.MESA_LOADER_DRIVER_OVERRIDE ||= 'llvmpipe'
} catch {
  // A production GPU driver can supply OpenGL without the optional Mesa files.
}
const results = []
for (let cycle = 1; cycle <= cycles; cycle += 1) {
  const reportPath = path.join(artifacts, `stress-${cycle}.json`)
  const stdoutPath = path.join(artifacts, `stress-${cycle}.stdout.log`)
  const stderrPath = path.join(artifacts, `stress-${cycle}.stderr.log`)
  const nativeTracePath = path.join(artifacts, `stress-${cycle}.native.log`)
  await Promise.all([
    fs.rm(reportPath, { force: true }),
    fs.rm(stdoutPath, { force: true }),
    fs.rm(stderrPath, { force: true }),
    fs.rm(nativeTracePath, { force: true })
  ])
  const stdout = await fs.open(stdoutPath, 'w')
  const stderr = await fs.open(stderrPath, 'w')
  const started = Date.now()
  const result = await new Promise((resolve) => {
    let settled = false
    const finish = (value) => {
      if (settled) return
      settled = true
      resolve(value)
    }
    const child = spawn(electron, [
      root,
      '--stress',
      `--stress-cycle=${cycle}`,
      `--stress-iterations=${iterations}`,
      `--stress-resizes=${resizes}`,
      `--stress-renderer-deaths=${rendererDeaths}`,
      `--stress-immediate-destroys=${immediateDestroys}`
    ], {
      cwd: root,
      env: { ...childEnvironment, GHOSTTY_EMBED_TRACE: nativeTracePath },
      stdio: ['ignore', stdout.fd, stderr.fd],
      windowsHide: false
    })
    const timeout = setTimeout(() => {
      if (process.platform === 'win32' && child.pid) {
        spawn('taskkill.exe', ['/pid', String(child.pid), '/T', '/F'], {
          stdio: 'ignore',
          windowsHide: true
        })
      } else {
        child.kill('SIGKILL')
      }
      setTimeout(
        () => finish({ cycle, exitCode: null, signal: 'timeout' }),
        10000
      ).unref()
    }, timeoutMs)
    child.once('exit', (exitCode, signal) => {
      clearTimeout(timeout)
      finish({ cycle, exitCode, signal })
    })
    child.once('error', (error) => {
      clearTimeout(timeout)
      finish({ cycle, exitCode: null, signal: null, error: error.message })
    })
  })
  await stdout.close()
  await stderr.close()
  result.durationMs = Date.now() - started
  try {
    result.report = JSON.parse(
      await fs.readFile(reportPath, 'utf8')
    )
  } catch (error) {
    result.reportError = error.message
  }
  result.pass = result.exitCode === 0 && result.report?.pass === true
  results.push(result)
  if (!result.pass) break
}

const summary = {
  cyclesRequested: cycles,
  cyclesCompleted: results.length,
  iterationsPerCycle: iterations,
  resizesPerIteration: resizes,
  rendererDeathsPerCycle: rendererDeaths,
  immediateDestroysPerCycle: immediateDestroys,
  totalSurfaces: results.reduce(
    (sum, value) => sum + (value.report?.surfacesCreated || 0),
    0
  ),
  totalResizes: results.reduce(
    (sum, value) => sum +
      (value.report?.iterations || 0) * (value.report?.resizesPerIteration || 0),
    0
  ),
  totalInjectedRendererDeaths: results.reduce(
    (sum, value) => sum + (value.report?.injectedRendererDeaths || 0),
    0
  ),
  results,
  pass: results.length === cycles && results.every((value) => value.pass)
}
await fs.writeFile(
  path.join(artifacts, 'stress-cycles.json'),
  `${JSON.stringify(summary, null, 2)}\n`
)
console.log(JSON.stringify(summary, null, 2))
if (!summary.pass) process.exitCode = 1
