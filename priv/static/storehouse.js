// Storehouse's uploader for LiveView: each file goes straight from the
// browser to the store (S3, or the app's own Storehouse.Local.Plug), with
// the request the server signed for it (Storehouse.Live.allow/3). Give it
// to the LiveSocket:
//
//     import {Uploaders} from "storehouse"
//     let liveSocket = new LiveSocket("/live", Socket, {uploaders: Uploaders, ...})
//
// With uploaders of your own: {...Uploaders, ...yours}.

export const Uploaders = {
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
        // 100 is for the store's answer: the file is there only then.
        const percent = Math.round((event.loaded / event.total) * 100);
        if (percent < 100) entry.progress(percent);
      });
      xhr.open(method, url, true);
      for (const [name, value] of Object.entries(headers || {})) xhr.setRequestHeader(name, value);
      xhr.send(entry.file);
    }
  },
};

export default Uploaders;
