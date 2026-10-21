interface Counter {
  value: number;
  readonly label: string;
}

const counter: Counter = { value: 0, label: "clicks" };

export function increment(step = 1): number {
  counter.value += step;
  const element = document.querySelector<HTMLSpanElement>("#count");
  if (element) {
    element.textContent = `${counter.value}`;
  }
  return counter.value;
}

const isEmail = (value: string) => /^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(value);

export async function loadGreeting(name: string): Promise<string> {
  const response = await fetch(`/api/greet?name=${encodeURIComponent(name)}`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return (await response.json()).message ?? "Hello!";
}
