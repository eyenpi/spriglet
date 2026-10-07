/* The website's clock and illustrated Mallow are independent of the Mac app. */
(() => {
  const scene = document.querySelector('[data-time-scene]');
  const clock = document.querySelector('[data-clock]');
  const footerClock = document.querySelector('[data-footer-clock]');
  const hello = document.querySelector('.notch-mallow');
  const greetingStatus = document.querySelector('[data-greeting-status]');
  if (!scene || !clock || !footerClock || !hello || !greetingStatus) return;

  let greetingTimer;
  let clockTimer;
  const formatTime = date => date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  function updateClock() {
    const now = new Date();
    const hour = now.getHours();
    const period = hour >= 5 && hour < 12 ? 'morning' : hour >= 12 && hour < 18 ? 'afternoon' : hour >= 18 && hour < 22 ? 'evening' : 'night';
    scene.dataset.period = period;
    clock.textContent = `${formatTime(now)} · ${clock.dataset[period]}`;
    footerClock.textContent = `${footerClock.dataset.prefix} ${formatTime(now).toLowerCase()}. `;
    clearTimeout(clockTimer);
    if (!document.hidden) clockTimer = setTimeout(updateClock, 60000 - now.getSeconds() * 1000 - now.getMilliseconds());
  }
  hello.disabled = false;
  hello.addEventListener('click', () => {
    clearTimeout(clockTimer);
    clearTimeout(greetingTimer);
    hello.classList.add('is-greeting');
    clock.textContent = hello.dataset.greeting;
    greetingStatus.textContent = hello.dataset.greeting;
    greetingTimer = setTimeout(() => { hello.classList.remove('is-greeting'); greetingStatus.textContent = ''; updateClock(); }, 2200);
  });
  document.addEventListener('visibilitychange', () => {
    clearTimeout(clockTimer);
    clearTimeout(greetingTimer);
    hello.classList.remove('is-greeting');
    greetingStatus.textContent = '';
    updateClock();
  });
  updateClock();
})();
