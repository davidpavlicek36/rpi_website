/* ── Drag-and-drop upload ─────────────────────────────────── */
(function () {
  const zone  = document.getElementById('drop-zone');
  const input = document.getElementById('file-input');
  const list  = document.getElementById('file-list');
  const btn   = document.getElementById('upload-btn');
  if (!zone) return;

  function showFiles(files) {
    list.hidden = files.length === 0;
    list.innerHTML = '';
    Array.from(files).forEach(function (f) {
      var d = document.createElement('div');
      d.textContent = f.name + ' (' + (f.size / 1024).toFixed(1) + ' KB)';
      list.appendChild(d);
    });
    btn.disabled = files.length === 0;
  }

  zone.addEventListener('click', function (e) {
    if (e.target.tagName !== 'LABEL') input.click();
  });

  input.addEventListener('change', function () {
    showFiles(this.files);
  });

  zone.addEventListener('dragover', function (e) {
    e.preventDefault();
    zone.classList.add('drag-over');
  });

  zone.addEventListener('dragleave', function () {
    zone.classList.remove('drag-over');
  });

  zone.addEventListener('drop', function (e) {
    e.preventDefault();
    zone.classList.remove('drag-over');
    // Assign dropped files to the input via DataTransfer
    input.files = e.dataTransfer.files;
    showFiles(e.dataTransfer.files);
  });
})();

/* ── Auto-dismiss flash messages after 5 s ────────────────── */
(function () {
  var flashes = document.querySelectorAll('.flash');
  flashes.forEach(function (el) {
    setTimeout(function () {
      el.style.transition = 'opacity .4s';
      el.style.opacity = '0';
      setTimeout(function () { el.remove(); }, 400);
    }, 5000);
  });
})();
