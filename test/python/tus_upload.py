# A tus client (tuspy) against the app's Storehouse.Tus.Plug
# (test/storehouse/tus_client_test.exs): one chunk sent, the client gone,
# then another that carries on from the server's offset. Prints the URL.
import sys
from tusclient import client

endpoint, path, name, filetype, chunk = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
tus = client.TusClient(endpoint)
metadata = {"filename": name, "filetype": filetype}

first = tus.uploader(path, chunk_size=chunk, metadata=metadata)
first.upload_chunk()

again = tus.uploader(path, chunk_size=chunk, url=first.url)
assert again.offset == chunk, again.offset
again.upload()
print(first.url)
