"""Makes LM test cases (one per line: context TAB text TAB text ...; the first
text is the true one):
  char  every split of a sentence: its prefix, then the homophones of the next character
  word  the same with two-character words
  big   48 eight-character texts after a short prefix: tries of 300-390 tokens, which the
        Core ML runtime has to split into several runs
    cases.py pinyin_readings.json char|word|big [width]"""
import itertools
import json
import random
import sys

SENTENCES = """今天天气很好我们一起去公园散步吧
这个问题我们明天再讨论
我想买一台新的笔记本电脑
他昨天晚上加班到很晚
请把文件发到我的邮箱
周末我打算去看望父母
这家餐厅的菜味道不错价格也合理
会议改到下午三点开始
我已经收到你的消息了
孩子们在操场上踢足球
你能帮我查一下航班信息吗
下雨了记得带伞
这本书讲的是一个关于成长的故事
我们需要尽快解决这个技术问题
他说话的声音很好听
明天早上八点在公司门口集合
输入法的候选词排序非常重要
我刚刚下班正在回家的路上
春节期间火车票很难买
医生建议他多喝水多休息
这次考试的成绩比上次进步了很多
我们公司正在招聘软件工程师
晚饭想吃什么你来决定吧
他把手机忘在出租车上了
这个周末有空的话一起去爬山
新的政策从下个月开始实施
她每天坚持跑步锻炼身体
谢谢你的帮助我非常感激
银行卡的密码不要告诉别人
我们的产品得到了客户的认可""".split()

BIG = ["今天天气很好我们一起去公园散步吧然后找个地方吃午饭", "这家餐厅的菜味道不错价格也合理服务员的态度也很好",
       "我们需要尽快解决这个技术问题否则会影响产品的发布时间", "春节期间火车票很难买大家最好提前一个月就开始准备"]


def main():
    readings = json.load(open(sys.argv[1], encoding="utf-8"))
    mode = sys.argv[2] if len(sys.argv) > 2 else "char"
    width = int(sys.argv[3]) if len(sys.argv) > 3 else 10

    def homophones(ch, limit):
        reading = readings["readings"].get(ch)
        if not reading:
            return [ch]
        pool = [c for c in readings["homophones"].get(reading[0], []) if c != ch]
        return [ch] + pool[: limit - 1]

    if mode == "big":
        random.seed(5)
        for sentence in BIG:
            for k in (6, 12, 18):
                context, rest = sentence[:k], sentence[k:k + 8]
                texts = {rest}
                while len(texts) < 48:
                    texts.add("".join(random.choice(homophones(c, 4)) if random.random() < 0.5 else c
                                      for c in rest))
                print("\t".join([context, rest] + sorted(texts - {rest})))
        return
    for sentence in SENTENCES:
        for k in range(1, len(sentence) - (1 if mode == "char" else 2) + 1):
            context = sentence[:k]
            if mode == "char":
                texts = homophones(sentence[k], width)
            else:
                a, b = sentence[k], sentence[k + 1]
                combos = [x + y for x, y in itertools.product(homophones(a, 4), homophones(b, 4))]
                texts = combos[:width]
            print("\t".join([context] + texts))


if __name__ == "__main__":
    main()
