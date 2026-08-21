import { randomBytes, randomInt } from "node:crypto";

const ADJECTIVES = [
  "amber", "brisk", "calm", "dusty", "eager", "fuzzy", "glassy", "happy",
  "icy", "jolly", "keen", "lazy", "merry", "noisy", "olive", "plucky",
  "quiet", "rusty", "silly", "tame", "umber", "vivid", "windy", "young",
  "zesty", "bold", "crisp", "dapper", "fancy", "gentle", "hazy", "lucky",
  "misty", "neat", "proud", "quick", "ruddy", "snug", "tidy", "warm",
];

const ANIMALS = [
  "otter", "badger", "cobra", "dingo", "ermine", "ferret", "gecko", "heron",
  "ibis", "jackal", "koala", "lynx", "marten", "newt", "owl", "panda",
  "quokka", "raven", "shrew", "tapir", "urchin", "viper", "weasel", "xerus",
  "yak", "zebu", "moose", "lemur", "stoat", "skunk", "puma", "wombat",
  "auk", "civet", "dhole", "fossa", "genet", "hyena", "kudu", "okapi",
];

export function generateChannelId(): string {
  const adj = ADJECTIVES[randomInt(0, ADJECTIVES.length)];
  const animal = ANIMALS[randomInt(0, ANIMALS.length)];
  const suffix = randomBytes(2).toString("hex");
  return `${adj}-${animal}-${suffix}`;
}

export function generateToken(): string {
  return `rt_${randomBytes(24).toString("base64url")}`;
}
