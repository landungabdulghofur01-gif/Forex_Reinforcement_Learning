const cities = [
  { name: 'New York', zone: 'America/New_York', icon: '◐' },
  { name: 'London', zone: 'Europe/London', icon: '◒' },
  { name: 'Jakarta', zone: 'Asia/Jakarta', icon: '◑' },
  { name: 'Tokyo', zone: 'Asia/Tokyo', icon: '◓' },
  { name: 'Dubai', zone: 'Asia/Dubai', icon: '◒' },
  { name: 'Sydney', zone: 'Australia/Sydney', icon: '◐' }
];

const grid = document.querySelector('#clock-grid');
const localTime = document.querySelector('#local-time');
const localDate = document.querySelector('#local-date');
const formatToggle = document.querySelector('#format-toggle');
const timezoneLabel = document.querySelector('#timezone-label');
let use24Hour = true;

const timeFormatter = (zone) => new Intl.DateTimeFormat('en-US', {
  timeZone: zone, hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: !use24Hour
});
const dateFormatter = (zone) => new Intl.DateTimeFormat('en-US', {
  timeZone: zone, weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
});
const zoneFormatter = (zone) => new Intl.DateTimeFormat('en-US', { timeZone: zone, timeZoneName: 'short' });

function renderCards() {
  grid.innerHTML = cities.map((city) => `
    <article class="clock-card" data-zone="${city.zone}">
      <div class="city-row"><div><div class="city-name">${city.name}</div><div class="city-zone">${city.zone.replace('_', ' ')}</div></div><div class="city-icon" aria-hidden="true">${city.icon}</div></div>
      <div class="card-time">--:--:--</div><div class="card-date">Loading…</div>
    </article>`).join('');
}

function updateClocks() {
  const now = new Date();
  const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  localTime.textContent = timeFormatter(localZone).format(now);
  localDate.textContent = dateFormatter(localZone).format(now);
  timezoneLabel.textContent = `Your timezone: ${localZone}`;

  document.querySelectorAll('.clock-card').forEach((card) => {
    const zone = card.dataset.zone;
    card.querySelector('.card-time').textContent = timeFormatter(zone).format(now);
    card.querySelector('.card-date').textContent = `${dateFormatter(zone).format(now)} · ${zoneFormatter(zone).formatToParts(now).find((part) => part.type === 'timeZoneName')?.value || ''}`;
  });
}

formatToggle.addEventListener('change', (event) => { use24Hour = event.target.checked; updateClocks(); });
renderCards();
updateClocks();
setInterval(updateClocks, 1000);
