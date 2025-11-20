param(
  # доступ
  [string]$Head       = "ec2-user@-------------",
  [string]$KeyPath    = "C:\Users\Administrator\Downloads\-----------",

  # локальна робоча тека (має містити gat.work.scm і папку src/)
  [string]$WorkDir    = "C:\Users\Administrator\Downloads\local-dir",

  # великий .msh ВЖЕ знаходиться на кластері — ми просто зробимо symlink
  [string]$RemoteMesh = "/shared/data/agard_v8[correct]_[100M].msh",

  # ресурси SLURM (за замовчуванням під 2 ноди hpc7a по 192 task)
  [string]$Partition  = "efa-queue",
  [int]   $Tasks      = 384,
  [string]$Mem        = "500G",
  [string]$TimeLimit  = "",  # напр. "72:00:00"; пусто = UNLIMITED

  # зручності
  [switch]$Follow,    # показати live-лог
  [switch]$ETA        # разово оцінити ETA
)

$ErrorActionPreference = 'Stop'

# --- перевірки локальних шляхів ---
if (!(Test-Path -LiteralPath $KeyPath)) {
  throw "Key not found: $KeyPath"
}
if (!(Test-Path -LiteralPath (Join-Path $WorkDir 'gat.work.scm'))) {
  throw "No gat.work.scm in $WorkDir"
}
if (!(Test-Path -LiteralPath (Join-Path $WorkDir 'src'))) {
  throw "No src/ dir in $WorkDir"
}

# --- шукаємо ssh.exe / scp.exe (Git for Windows) ---
$SSH_EXE = (Get-Command 'ssh.exe' -CommandType Application -ErrorAction SilentlyContinue).Source
$SCP_EXE = (Get-Command 'scp.exe' -CommandType Application -ErrorAction SilentlyContinue).Source

if (-not $SSH_EXE) { throw "ssh.exe not found in PATH" }
if (-not $SCP_EXE) { throw "scp.exe not found in PATH" }

function SSH {
  param(
    [Parameter(Mandatory=$true)][string]$Cmd
  )
  & $SSH_EXE -i $KeyPath $Head $Cmd
}

function SCP {
  param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Dst
  )
  # копіюємо локальний файл на кластер
  $host = $Head.Split('@')[1]
  & $SCP_EXE -i $KeyPath $Src ("{0}:{1}" -f $host, $Dst)
}

function SCPR {
  param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Dst
  )
  # копіюємо з кластера на локальну машину
  $host = $Head.Split('@')[1]
  & $SCP_EXE -i $KeyPath ("{0}:{1}" -f $host, $Src) $Dst
}

Push-Location $WorkDir
try {
  # --- 1) створюємо віддалену JOB-теку ---
  $JOB = SSH 'mktemp -d /shared/jobs/gat.XXXXXXXXX' | Select-Object -Last 1
  if (-not $JOB) {
    throw "Не вдалося створити віддалений JOB-директорій"
  }
  Write-Host "JOB dir on cluster: $JOB"

  # --- 2) копіюємо робочі файли ---

  # основний .scm
  SCP (Join-Path $WorkDir 'gat.work.scm') "$JOB/gat.work.scm"

  # src/
  SSH "mkdir -p '$JOB/src'"
  $localSrc = Join-Path $WorkDir 'src'
  Get-ChildItem -Recurse $localSrc | ForEach-Object {
    if (-not $_.PSIsContainer) {
      $rel = $_.FullName.Substring($localSrc.Length).TrimStart('\','/')
      $remotePath = ("{0}/src/{1}" -f $JOB, $rel.Replace('\','/'))
      $remoteDir  = [System.IO.Path]::GetDirectoryName($remotePath)
      SSH "mkdir -p '$remoteDir'"
      SCP $_.FullName $remotePath
    }
  }

  # symlink на великий .msh (перевіряємо, що існує)
  $meshBase = "mesh.msh"
  SSH "[[ -f '$RemoteMesh' ]] || { echo 'MESH NOT FOUND: $RemoteMesh' >&2; exit 1; }"
  SSH "ln -sf '$RemoteMesh' '$JOB/$meshBase'"

  # --- 3) генеруємо gat.work.io2.scm з io-mode 2 (як у старому скрипті) ---
  $inject = @'
#!/bin/bash
set -euo pipefail
JOB="$1"
IN="$JOB/gat.work.scm"
OUT="$JOB/gat.work.io2.scm"
cp -f "$IN" "$IN.bak"
awk '{
  print;
  if (index($0,"(*gat-default-settings)")) print "/file/cffio-options/io-mode 2";
  if (index($0,"(*read-case"))          print "/file/cffio-options/io-mode 2";
}' "$IN" > "$OUT"
grep -n "cffio-options/io-mode" "$OUT" | head -n2 || true
'@

  $injectLocal = Join-Path $env:TEMP 'inject_io2.sh'
  [IO.File]::WriteAllText($injectLocal, ($inject -replace "`r`n","`n"), [System.Text.Encoding]::ASCII)
  SCP $injectLocal "/tmp/inject_io2.sh"
  Remove-Item $injectLocal -Force
  SSH "sed -i 's/\r$//' /tmp/inject_io2.sh"
  SSH "chmod +x /tmp/inject_io2.sh; /tmp/inject_io2.sh '$JOB'"

  # --- 4) генеруємо SLURM-скрипт під hpc7a + Intel MPI ---
  $sbTemplate = @'
#!/bin/bash
#SBATCH -J gat
#SBATCH -p __PARTITION__
#SBATCH -N 2
#SBATCH --ntasks=__NTASKS__
#SBATCH --ntasks-per-node=192
#SBATCH --mem=__MEM__
__TIMELIMIT__
#SBATCH -D __JOBDIR__
#SBATCH -o __JOBDIR__/slurm-%j.out
#SBATCH -e __JOBDIR__/slurm-%j.err
set -xeuo pipefail

export OMP_NUM_THREADS=1
export ANSYSLI_SERVERS=2325@--------------
export ANSYSLMD_LICENSE_FILE=1055@-------------------------

# Fluent у PATH
export PATH=/shared/ansys_inc/v202/fluent/bin:$PATH
ulimit -s unlimited

# Intel MPI (Fluent multiport) + EFA
export MPI_ROOT=/shared/ansys_inc/v202/fluent/fluent20.2.0/multiport/mpi/lnamd64/intel
export LD_LIBRARY_PATH=$MPI_ROOT/lib:${LD_LIBRARY_PATH-}

# Intel MPI + EFA (libfabric/ofi)
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=efa
export I_MPI_PIN_DOMAIN=socket

# зробимо файл із хостами з вашого SLURM-алока
scontrol show hostnames "$SLURM_NODELIST" > __JOBDIR__/hosts
cat __JOBDIR__/hosts

fluent 3ddp -g -t${SLURM_NTASKS} -mpi=intel -cnf="__JOBDIR__/hosts" -i gat.work.io2.scm
'@

  $timeLine = if ($TimeLimit) { "#SBATCH -t $TimeLimit" } else { "" }

  $sb = $sbTemplate `
    -replace '__PARTITION__',   [Regex]::Escape($Partition) `
    -replace '__NTASKS__',      [Regex]::Escape("$Tasks") `
    -replace '__MEM__',         [Regex]::Escape($Mem) `
    -replace '__TIMELIMIT__',   [Regex]::Escape($timeLine) `
    -replace '__JOBDIR__',      [Regex]::Escape($JOB)

  $sbLocal = Join-Path $env:TEMP 'run.sbatch'
  $sbLF = $sb -replace "`r`n","`n"
  [IO.File]::WriteAllText($sbLocal, $sbLF, [System.Text.Encoding]::ASCII)
  SCP $sbLocal "$JOB/run.sbatch"
  Remove-Item $sbLocal -Force
  SSH "sed -i 's/\r$//' '$JOB/run.sbatch'"

  # --- 5) сабмітимо job ---
  $submit = SSH "cd '$JOB' && sbatch run.sbatch"
  $submit | Write-Host
  if ($submit -match 'Submitted batch job (\d+)') {
    $JID = $Matches[1]
  } else {
    throw "Cannot parse JobID from: $submit"
  }
  "JID=$JID  JOB=$JOB" | Write-Host

  # --- 6) опційний live-лог ---
  if ($Follow) {
    SSH "until [ -f $JOB/slurm-$JID.out ]; do sleep 1; done; tail -n +1 -f $JOB/slurm-$JID.out -f $JOB/slurm-$JID.err"
  }

  # --- 7) опційна ETA ---
  if ($ETA) {
    $eta = @'
#!/bin/bash
set -euo pipefail
JOBDIR="${1:-.}"
TARGET="${2:-10000}"

find_log() {
  ls -1t "$JOBDIR"/m*/log* "$JOBDIR"/log* 2>/dev/null | head -1
}

get_iter() {
  grep -E "^(iter|Iteration)[[:space:]]*[0-9]+" "$1" 2>/dev/null | tail -1 | sed -E "s/[^0-9]*([0-9]+).*/\1/"
}

LOG="$(find_log || true)"
if [[ -z "${LOG:-}" ]]; then
  echo "No log file found under $JOBDIR"
  exit 1
fi

i0="$(get_iter "$LOG" || true)"
i0="${i0:-0}"

if [[ "$i0" -le 0 ]]; then
  echo "Waiting for iterations to appear in log..."
  sleep 120
  LOG="$(find_log || true)"
  if [[ -z "${LOG:-}" ]]; then
    echo "Log disappeared"
    exit 2
  fi
  i0="$(get_iter "$LOG" || true)"
  i0="${i0:-0}"
fi

if [[ "$i0" -le 0 ]]; then
  echo "Still no iterations detected, cannot compute ETA"
  exit 3
fi

t0=$(date +%s)
sleep 120
LOG="$(find_log || true)"
if [[ -z "${LOG:-}" ]]; then
  echo "Log disappeared on second read"
  exit 4
fi
i1="$(get_iter "$LOG" || true)"
i1="${i1:-$i0}"
t1=$(date +%s)
dt=$((t1 - t0))
if (( dt <= 0 || i1 <= i0 )); then
  echo "ETA window too small (i0=$i0 i1=$i1 dt=${dt}s)"
  exit 5
fi

rate=$(awk -v a="$i0" -v b="$i1" -v d="$dt" "BEGIN{print (b-a)/d}")
left=$(( TARGET - i1 ))
if (( left <= 0 )); then
  echo "ETA: done (i=$i1 / $TARGET)"
  exit 0
fi

eta_sec=$(awk -v l="$left" -v r="$rate" "BEGIN{printf \"%.0f\", (r>0? l/r : 1e12)}")
end_ts=$(( $(date +%s) + eta_sec ))

printf "iter_now=%d / %d\n" "$i1" "$TARGET"
printf "rate=%.3f iter/s\n" "$rate"
printf "ETA ~ %s  (~%dh %dm)\n" "$(date -d "@$end_ts" '+%Y-%m-%d %H:%M:%S %Z')" "$((eta_sec/3600))" "$(((eta_sec%3600)/60))"
'@

    $etaLocal = Join-Path $env:TEMP 'fluent_eta.sh'
    [IO.File]::WriteAllText($etaLocal, ($eta -replace "`r`n","`n"), [System.Text.Encoding]::ASCII)
    SCP $etaLocal "/tmp/fluent_eta.sh"
    Remove-Item $etaLocal -Force
    SSH "sed -i 's/\r$//' /tmp/fluent_eta.sh"
    SSH "chmod +x /tmp/fluent_eta.sh; /tmp/fluent_eta.sh '$JOB' 10000 || true"
    Write-Host "Повторити пізніше: ssh -i `"$KeyPath`" $Head /tmp/fluent_eta.sh '$JOB' 10000"
  }

  # --- 8) короткі підказки моніторингу ---
  Write-Host "`nМоніторинг:"
  Write-Host "  ssh -i `"$KeyPath`" $Head `"squeue -j $JID -o '%9i %8T %10M elapsed %40R'`""
  Write-Host "  ssh -i `"$KeyPath`" $Head `"scontrol show job $JID | egrep 'StartTime=|RunTime=|EndTime='`""
  Write-Host "  ssh -i `"$KeyPath`" $Head `"tail -n +1 -f $JOB/slurm-$JID.out -f $JOB/slurm-$JID.err`""
}
finally {
  Pop-Location
}
