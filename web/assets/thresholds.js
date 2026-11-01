// All values are illustrative recommendations calculated on this device.
const capacity = document.getElementById('capacity');
const pause = document.getElementById('pause');
const emergency = document.getElementById('emergency');
const scaleEnd = document.getElementById('scale-end');
function showThresholds() {
  const gib = Number(capacity.value);
  pause.textContent = String(gib * 0.5);
  emergency.textContent = String(gib * 0.625);
  scaleEnd.textContent = gib + ' GiB';
}
capacity.addEventListener('change', showThresholds);
showThresholds();
document.getElementById('capacity-control').hidden = false;
