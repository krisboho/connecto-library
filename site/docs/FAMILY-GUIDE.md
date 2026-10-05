# Connecto Library — family guide

One website for our books. Search for a book, download it, and send it to your Kindle or read it on an iPad.

## Where it is
- At home: http://192.168.0.9:8430
- Anywhere, with Tailscale on: http://100.95.26.46:8430
- Log in with your library username and password (the same one as the Grimmory library).

Tip for phones and iPads: open the site in Safari, tap Share, then **Add to Home Screen**. It then works like an app with a tab bar at the bottom.

## Find and download a book
1. **Search** and type the title or author.
2. Tap **Find copies** on the right book.
3. Tap **Download** on the first copy. EPUB copies are listed first and are the best for Kindles and iPads.
4. **Downloads** shows progress. When it says **In library**, the book is in.

If a download fails, tap **Retry** or **Other copies**.

## Send a book to your Kindle
1. In **Library**, find the book and tap **Send to my Kindle**.
2. Wake the Kindle up. It picks up new books on its own within about a minute.
3. To take a book off your Kindle, tap **Remove from my Kindle**. It disappears from the Kindle at its next sync, but stays in the library.

The first time, the site asks you to **Create my Kindle shelf**. Tap it once.

**How long does it take?** A normal novel arrives in a few seconds. Cookbooks and comics with lots of pictures can be 100 MB or more (the size is shown on the book's card) and take a minute or two. On the Kindle, open **Tools → Shelf Sync → Sync now** to watch it: you'll see the book name, the percent done and the speed. Tap the box to hide it; the sync keeps going. Automatic syncs show short messages at the top of the screen instead.

## Read on an iPad
Do this once per iPad.

**Tailscale** (lets the iPad reach the library from anywhere)
1. Install **Tailscale** from the App Store.
2. Sign in with the family Tailscale login and allow the VPN prompt.
3. Leave it switched on. It only carries traffic to home.

**Readest** (the reading app)
1. Install **Readest** from the App Store (free).
2. On the site, open **Library → On my Kindle**. Copy the address shown under **Use this list on an iPad**.
3. In Readest, add a catalog with that address and your OPDS login. The catalog shows exactly the books you've sent to your Kindle.
4. Turn on reading-position sync: choose KOReader sync, server `http://100.95.26.46:6060/api/koreader`, same username and password as the KOReader sync login.
5. Tap a book in the catalog to download it, and read. Your place syncs with your Kindle.

Sending a book to your Kindle does **not** push it to the iPad by itself. It appears in the Readest catalog, and you tap it once to download. That's an Apple limitation, not something we can change.

Want the whole library instead of just your list? Use `http://100.95.26.46:6060/api/v1/opds` as the catalog address.

Your library profile needs an OPDS login and a KOReader sync login for this. Ask Kris if yours isn't set up.

## Who can do what
- Everyone can search, download, and send books to their own Kindle.
- Only Kris can delete a book from the library or change settings.
