// The CommonJS build of storehouse.js (see it for the uploader's docs).
"use strict";

const Uploaders = {
  Storehouse(entries, onViewError) {
    for (const entry of entries) {
      const { method, url, headers } = entry.meta;
      const xhr = new XMLHttpRequest();
      onViewError(() => xhr.abort());
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) entry.progress(100);
        else entry.error(`the store answered ${xhr.status}`);
      };
      xhr.onerror = () => entry.error("the upload failed");
      xhr.upload.addEventListener("progress", (event) => {
        if (!event.lengthComputable) return;
        const percent = Math.round((event.loaded / event.total) * 100);
        if (percent < 100) entry.progress(percent);
      });
      xhr.open(method, url, true);
      for (const [name, value] of Object.entries(headers || {})) xhr.setRequestHeader(name, value);
      xhr.send(entry.file);
    }
  },
};

module.exports = { Uploaders, default: Uploaders };
