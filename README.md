# piped-test

SurSathi app se bilkul alag, chhota repo — sirf YouTube search/audio-URL
logic ko **fast** test karne ke liye (~15-20 second, poori Flutter APK
build (2-3 min) nahi karni padti).

> **Note:** Ab ye Piped public instances par depend nahi karta (wo saare
> 2026 tak YouTube ke crackdown se dead/blocked ho chuke hain). Iski jagah
> `youtube_explode_dart` use hota hai, jo seedha YouTube se extract karta
> hai — koi third-party instance ki zaroorat nahi.

## Use kaise karo

1. `bin/piped_test.dart` me jo bhi logic change karni hai wo karo (ye
   `SurSathi/lib/services/youtube_service.dart` ka hi standalone copy hai).
2. Poora folder zip karke is repo me push karo (jaisa SurSathi wale repo
   me hota hai — `extract.yml` khud extract+clean+commit kar dega).
3. **Actions** tab me "Test Piped Logic" run dekho — chand second me
   PASS/FAIL pata chal jaayega, poori log me kaunsa instance/step fail
   hua wo bhi dikhega.
4. Jab yahan test PASS ho jaaye, TABHI wahi verified logic SurSathi wale
   `youtube_service.dart` me copy karo aur asli APK build karo.

## Custom query/video test karna ho

`bin/piped_test.dart` ke `main()` me CLI args support hai:
```
dart run bin/piped_test.dart "kishore kumar" dQw4w9WgXcQ
```
Pehla arg = search query, doosra arg = video ID jiska audio URL resolve
karna hai. GitHub Actions se custom args nahi diye ja sakte (workflow
hardcoded query/videoId use karta hai) — wo sirf local run ke liye hai.
