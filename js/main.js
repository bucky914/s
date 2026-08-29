// =========================================================
// General site interactions
// =========================================================

document.addEventListener('DOMContentLoaded', () => {
  // Mobile nav toggle
  const navToggle = document.getElementById('navToggle');
  const mainNav = document.getElementById('mainNav');
  if (navToggle && mainNav) {
    navToggle.addEventListener('click', () => {
      const isOpen = mainNav.classList.toggle('open');
      navToggle.setAttribute('aria-expanded', isOpen);
    });
    // Close menu after clicking a link (mobile)
    mainNav.querySelectorAll('a').forEach(link => {
      link.addEventListener('click', () => {
        mainNav.classList.remove('open');
        navToggle.setAttribute('aria-expanded', 'false');
      });
    });
  }

  // Footer year
  const yearEl = document.getElementById('year');
  if (yearEl) yearEl.textContent = new Date().getFullYear();

  // Generic WhatsApp contact link
  const waLink = document.getElementById('contactWhatsapp');
  if (waLink) {
    waLink.href = `https://wa.me/${OWNER_WHATSAPP_NUMBER}?text=${encodeURIComponent('Hi, I\'d like to know more about Just Detail services.')}`;
  }

  // Toggle between plain "Care Plan Login" link and account dropdown
  // depending on whether the visitor has an active session.
  const navLoginLink = document.getElementById('navLoginLink');
  const navAccountMenu = document.getElementById('navAccountMenu');
  const navAccountBtn = document.getElementById('navAccountBtn');
  const navAccountDropdown = document.getElementById('navAccountDropdown');
  const navAccountName = document.getElementById('navAccountName');
  const navLogoutBtn = document.getElementById('navLogoutBtn');

  async function refreshAccountState() {
    if (!navLoginLink || !navAccountMenu || typeof supabaseClient === 'undefined') return;

    const { data } = await supabaseClient.auth.getUser();
    if (data && data.user) {
      navLoginLink.style.display = 'none';
      navAccountMenu.style.display = 'block';

      // Try to show the client's first name instead of a generic "Account"
      const { data: clientRow } = await supabaseClient
        .from('clients')
        .select('full_name')
        .eq('id', data.user.id)
        .maybeSingle();
      if (clientRow && clientRow.full_name) {
        navAccountName.textContent = clientRow.full_name.split(' ')[0];
      }
    } else {
      // No active session (or it just ended) — make sure the UI reflects
      // that, rather than leaving a stale "My Dashboard" state on screen.
      navLoginLink.style.display = '';
      navAccountMenu.style.display = 'none';
    }
  }

  refreshAccountState();

  // If this page is restored from the browser's back/forward cache (e.g.
  // the user logs out elsewhere, then hits Back), scripts don't re-run on
  // their own — re-check the session so the nav doesn't show stale state.
  window.addEventListener('pageshow', (event) => {
    if (event.persisted) refreshAccountState();
  });

  if (navAccountBtn && navAccountDropdown) {
    navAccountBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const isOpen = navAccountDropdown.classList.toggle('open');
      navAccountBtn.setAttribute('aria-expanded', String(isOpen));
    });
    document.addEventListener('click', () => {
      navAccountDropdown.classList.remove('open');
      navAccountBtn.setAttribute('aria-expanded', 'false');
    });
  }

  if (navLogoutBtn) {
    navLogoutBtn.addEventListener('click', async () => {
      if (typeof supabaseClient !== 'undefined') {
        await supabaseClient.auth.signOut();
      }
      window.location.reload();
    });
  }

  // Before/After gallery slider — drag only starts from the center handle,
  // so it never fights with normal page scrolling on mobile.
  const baTile = document.getElementById('beforeAfterTile');
  const baHandle = document.getElementById('baHandle');
  const baBeforeImage = document.getElementById('baBeforeImage');

  if (baTile && baHandle && baBeforeImage) {
    let dragging = false;

    function setSplit(clientX) {
      const rect = baTile.getBoundingClientRect();
      let percent = ((clientX - rect.left) / rect.width) * 100;
      percent = Math.max(0, Math.min(100, percent));
      baBeforeImage.style.clipPath = `inset(0 ${100 - percent}% 0 0)`;
      baHandle.style.left = `${percent}%`;
    }

    function startDrag() {
      dragging = true;
      baTile.classList.add('ba-dragging');
    }
    function moveDrag(e) {
      if (!dragging) return;
      const clientX = e.touches ? e.touches[0].clientX : e.clientX;
      setSplit(clientX);
    }
    function endDrag() {
      dragging = false;
      baTile.classList.remove('ba-dragging');
    }

    baHandle.addEventListener('mousedown', startDrag);
    baHandle.addEventListener('touchstart', startDrag, { passive: true });

    document.addEventListener('mousemove', moveDrag);
    document.addEventListener('touchmove', moveDrag, { passive: true });

    document.addEventListener('mouseup', endDrag);
    document.addEventListener('touchend', endDrag);
  }
});
