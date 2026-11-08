import { browser } from 'wxt/browser';
import { defineContentScript } from 'wxt/utils/define-content-script';
import { PageFiller, sameOriginWithTop } from '@/lib/page-filler';
import { parseFillMessage, type ContentMessage } from '@/lib/protocol';
import { pageIconLinks, parseIconLinksMessage } from '@/lib/site-icon';

function send(msg: ContentMessage): void {
  // Fails when the extension was reloaded under this page; nothing to do then.
  browser.runtime.sendMessage(msg).catch(() => {});
}

export default defineContentScript({
  matches: ['<all_urls>'],
  allFrames: true,
  runAt: 'document_idle',
  main() {
    const filler = new PageFiller({
      document,
      origin: location.origin,
      frameAllowed: () => sameOriginWithTop(window),
      notifyPasswordFilled: () => send({ type: 'filled', password: true }),
    });

    browser.runtime.onMessage.addListener((raw: unknown, _sender, sendResponse: (answer: unknown) => void) => {
      const iconAsk = parseIconLinksMessage(raw);
      if (iconAsk) {
        // Only the top frame, and only while it is still on the page the app asked about.
        sendResponse(window.top === window && location.origin === iconAsk.origin ? pageIconLinks(document) : []);
        return false;
      }
      const msg = parseFillMessage(raw);
      if (!msg) return false;
      sendResponse(filler.handle(msg));
      return false;
    });

    send({ type: 'ready' });

    if (window.top === window) {
      window.addEventListener('focus', () => send({ type: 'focus' }));
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') send({ type: 'focus' });
      });
    }
  },
});
