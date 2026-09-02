;;; bookmark-gt-browser-tab-names-tests.el --- tab name conflicts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tab titles repeat, so a refresh meets name conflicts routinely.
;; It skips what the same-name policy refuses rather than
;; signalling; see the Commentary in bookmark-gt-browser-tabs.el.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-browser-tabs)

(defun bookmark-gt-browser-tab-names-test--store (title url)
  "Store a tab named TITLE at URL, returning non-nil when stored."
  (bookmark-gt-browser-tabs--store
   (list :title title :url url :id (random 100000)
         :browser-gt-browser "test")))

(ert-deftest bookmark-gt-browser-tab-names-test-always-stores-both ()
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'always))
      (should (bookmark-gt-browser-tab-names-test--store "Inbox" "https://a"))
      (should (bookmark-gt-browser-tab-names-test--store "Inbox" "https://b"))
      (should (= 2 (length (bookmark-gt--records-named "Inbox")))))))

(ert-deftest bookmark-gt-browser-tab-names-test-different-url-is-stored ()
  "Same title, different URL: two destinations, both kept."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'different-destination))
      (should (bookmark-gt-browser-tab-names-test--store "Inbox" "https://a"))
      (should (bookmark-gt-browser-tab-names-test--store "Inbox" "https://b"))
      (should (= 2 (length (bookmark-gt--records-named "Inbox")))))))

(ert-deftest bookmark-gt-browser-tab-names-test-same-url-is-skipped ()
  "The same page open twice is one bookmark, not an error."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'different-destination))
      (should (bookmark-gt-browser-tab-names-test--store "Inbox" "https://a"))
      (should-not (bookmark-gt-browser-tab-names-test--store "Inbox" "https://a"))
      (should (= 1 (length (bookmark-gt--records-named "Inbox")))))))

(ert-deftest bookmark-gt-browser-tab-names-test-never-keeps-the-first ()
  "With `never', the first tab of a title is stored and the rest skipped."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'never))
      (should (bookmark-gt-browser-tab-names-test--store "Inbox" "https://a"))
      (should-not (bookmark-gt-browser-tab-names-test--store "Inbox" "https://b"))
      (let ((kept (bookmark-gt--records-named "Inbox")))
        (should (= 1 (length kept)))
        (should (equal (bookmark-gt-url-of (car kept)) "https://a"))))))

(ert-deftest bookmark-gt-browser-tab-names-test-refresh-never-signals ()
  "A conflict skips the tab; it does not abandon the refresh."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'never))
      (bookmark-gt-browser-tab-names-test--store "Inbox" "https://a")
      (should-not
       (condition-case err
           (progn (bookmark-gt-browser-tab-names-test--store "Inbox" "https://b")
                  nil)
         (error err))))))

(provide 'bookmark-gt-browser-tab-names-tests)

;;; bookmark-gt-browser-tab-names-tests.el ends here
