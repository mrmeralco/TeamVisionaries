# Solaris Presentation Outline and Speaker Script

**Recommended length:** 8–10 minutes  
**Format:** 14 slides followed by a live demonstration

---

## Slide 1 — The Catch

### On-screen text

> You invested in solar to lower your electricity bill.  
> So why is the bill still a surprise?

### Speaker script

Families invest in solar because they expect lower electricity costs and greater energy independence.

But many solar owners still receive bills that are higher than expected. They cannot easily tell how much energy their panels produced, how much electricity they bought from the grid, or whether their battery was used efficiently.

And the many homes without solar have the same problem: the meter turns all month, and the only explanation arrives with the bill.

### Suggested visual

Show a homeowner looking at an unexpectedly high electricity bill beside a house with solar panels.

---

## Slide 2 — The Customer Problem

### Title

**Owning the equipment does not mean understanding the energy**

### On-screen points

- Customers cannot easily connect their daily energy use to their monthly bill.
- Smart meters and hybrid inverters often display technical information.
- Solar production, battery use, and grid consumption may appear in separate systems.
- Customers discover problems only after receiving a high bill.
- A new appliance or an always-on load can raise the bill for weeks before anyone notices.
- Predicting future consumption and expenses remains difficult.

### Speaker script

Solar panels can reduce electricity costs, but customers still need to understand how their entire energy system behaves.

Was there not enough sunlight? Did the household consume more energy at night? Was the battery empty? Did the family buy a new air conditioner? Is something staying on all day while nobody is home?

Most systems provide readings, but they do not clearly explain what those readings mean for the customer’s bill.

---

## Slide 3 — Introducing Solaris

### Title

**Solaris explains where the energy and money go**

### On-screen text

> A smart energy monitoring device and mobile application for every home: with solar, or with only a meter

### Speaker script

That is why we created **Solaris**.

Solaris is a monitoring device that connects to compatible smart meters and hybrid inverters. It reads the home’s solar production, household consumption, grid usage, battery status, and inverter condition.

Solaris works in three setups:

| Setup | What Solaris reads | Who it is for |
|---|---|---|
| **Solar** | Hybrid inverter | Homes with solar panels and a battery |
| **Smart meter mode** | Smart meter or Meralco meter only | Homes without solar |
| **Solar + meter** | Both; the meter supplies the billed kWh | Solar homes that want the exact number Meralco bills |

Our system analyzes these readings and presents them through a simple mobile application. Customers can see what is happening now, understand what happened before, and prepare for what may happen next.

### Suggested visual

Show the Solaris device beside a phone displaying the mobile application, with two small house icons: one with solar panels, one with only a meter.

---

## Slide 4 — How Solaris Works

### Title

**From the energy system to the customer’s phone**

### System flow

```text
Hybrid inverter  and/or  Smart meter / Meralco meter
                    ↓
          Solaris monitoring device
                    ↓
  Local server: history, forecasts, household profile
                    ↓
         Solaris mobile application
                    ↓
          Mira AI energy assistant
```

### Speaker script

The Solaris device reads information directly from the hybrid inverter, the smart meter, or both.

It sends the readings to our local server, which stores the household’s energy history, detects important events, calculates costs, learns the household’s routine, and produces forecasts.

Everything runs on a computer inside the home, including Mira. The household’s data, including when the family is usually home, never leaves the house.

The Solaris app then turns the data into information that customers can understand. Mira, our AI energy assistant, helps explain what the numbers mean and what actions the customer can take.

---

## Slide 5 — Live Home Monitoring

### Title

**What is happening at home right now**

### App features to show

- Current solar production
- Household electricity consumption
- Grid power, clearly labelled as importing or exporting
- Battery percentage and charging status
- Estimated savings for the day
- Inverter temperature and fault status
- Device connection and Wi-Fi status
- Brownout advisor: how long the battery would last if the power went out now

### Speaker script

On the Solaris Home screen, customers can immediately see where their electricity is coming from and where it is going.

If solar production is higher than the household load, the app shows that the battery is charging. If solar production is low, it shows whether the home is using the battery or buying electricity from the grid. When the home sends extra solar to the grid, the app says “Exporting”, so the customer never mistakes it for buying power.

The Brownout advisor card answers a question every Filipino household asks: if the power goes out now, how long will we last?

The information updates live. Customers can switch on an appliance and see its effect on household consumption within seconds.

---

## Slide 6 — Energy History and Bill Forecast

### Title

**The electricity bill becomes predictable**

### App features to show

- Daily, weekly, and monthly consumption
- Solar generation and grid usage
- Current month-to-date cost, priced with Meralco’s residential rate levels
- Predicted bill at the end of the month, with a low and high range
- Coming months: up to three months ahead, clearly marked as estimates
- Comparison with the previous month
- Estimated solar savings

### Speaker script

Solaris does more than show current readings. It studies the household’s energy history.

Customers can review their consumption by day, week, or month. The system estimates the current cost and predicts the bill at the end of the month. The forecast follows the household’s level over the last 14 days, so it reacts quickly when the weather turns hot or the family’s habits change.

We tested this honestly. We ran the forecast against a full simulated year for several households and checked how often the real bill landed inside the range we showed. That testing made our ranges more truthful: the month-end error dropped by up to 38 percent in the middle of the month.

Solaris also shows the next three months. Only this month is called a forecast. Later months are labelled as estimates, and their range widens the further ahead they are. We stop at three months, because beyond that the range would be too wide to be useful.

Instead of waiting for the final bill, the customer receives an early warning and has enough time to adjust their energy use.

---

## Slide 7 — Solar and Battery Prediction

### Title

**Planning for tomorrow’s energy needs**

### App features to show

- Expected solar production for the next 48 hours
- Weather-informed forecast using hourly solar radiation and cloud conditions
- Forecast calibrated with the home’s actual solar performance
- Projected battery percentage
- Expected grid consumption
- Estimated time until the battery reaches its reserve
- Estimated battery runtime during a brownout, including the expected sun
- History-based forecast when weather data is unavailable

### Speaker script

Solaris also looks ahead.

Solaris estimates the next 48 hours of solar generation using hourly solar-radiation forecasts from Open-Meteo. It calibrates the forecast using the home’s actual solar production from the previous seven days, allowing the prediction to reflect the performance of that specific installation.

If there is not yet enough household data, Solaris starts with the configured solar-panel capacity and typical system losses. If weather information or internet access is unavailable, it falls back to the home’s average solar production for each hour from the previous 14 days.

Solaris combines the expected solar generation with the household’s usual hourly consumption. It then projects the battery percentage, expected grid use, the time when the battery may reach its reserve, and whether the next day’s sunlight may recharge it.

During a brownout, the app estimates how long the battery can support the current household load, counting the sun that is still expected. This helps the customer decide whether to continue normal use or turn off appliances that consume a large amount of electricity.

---

## Slide 8 — Solar Tips and System Check

### Title

**Getting more from the sun the household already has**

### App features to show

- **Best window today:** the three sunniest hours with the most spare solar, such as “10AM–1PM”
- **Right now:** “You are sending solar to the grid, run the washing machine now” or “You are buying from the grid, wait for the sunny window”
- **Habit tips** from the last 30 days, ordered by the money they could save
- **Clean energy this month:** share of home use not from the grid, CO₂ avoided, and the equivalent number of trees
- **System check:** does the solar, battery, and inverter still fit the household? Recommendations with rough savings and payback

### Speaker script

Solar only saves money when the household uses it. Solaris tells the family when the sun is strongest today, and what to do right now.

If the home is sending solar to the grid while it buys electricity every night, Solaris suggests shifting laundry, ironing, or cooling into the day, and shows how much that could save each month.

Every month, the customer also sees their clean-energy impact: how much carbon dioxide their panels avoided, in a number anyone can picture.

Finally, the system check looks at the last 30 days and asks whether the equipment still fits the household. If the battery runs empty every night while solar goes to waste during the day, Solaris recommends a battery upgrade, with an estimated monthly saving and payback period. We label these as estimates; the installer gives the exact quote.

---

## Slide 9 — Getting to Know the Household

### Title

**Solaris learns the home’s routine from its electricity use alone**

### App features to show

- **Household type:** for example, “Away during weekdays” or “Someone is home during the day”
- **Daily routine:** usual wake-up time, sleep time, time away, and the busiest hour
- **Right now:** whether someone is likely home, asleep, or away, compared with the usual routine
- **Unusual activity:** use at an hour that is normally quiet
- **Always-on load:** the electricity used even when nobody is using anything, in kWh and pesos per month
- **New appliance detection:** “Since Nov 7, about 1.1 kW more every night from 9PM to 2AM. A new air conditioner?”

### Speaker script

Solaris does not need cameras or extra sensors to understand a household. The home’s electricity use already tells the story.

Using only the household’s power readings, averaged every 15 minutes, Solaris learns when the family usually wakes up, leaves, comes home, and sleeps, on weekdays and on weekends.

That profile makes everything else more personal. Solaris can see that a home is quiet during the day but still draws 280 watts, and tells the family that this always-on load costs about ₱3,000 a month. It can notice when a new load appears every night and ask whether the family bought a new air conditioner, before the higher bill arrives.

Because this information is personal, the profile is computed on the home’s own computer and never leaves the house.

### Suggested visual

Show the Household card: the 24-hour activity strip, the “likely home now” status, and the new-appliance message.

---

## Slide 10 — Smart Meter Mode

### Title

**Solaris for homes without solar**

### App features to show

- Live meter reading: power, voltage, current, and power factor
- Voltage quality: whether the supply is normal, too low, or too high, with the last 24 hours’ minimum and maximum
- Usage pattern: daily use, peak hours, night share, and weekday versus weekend use
- **Meralco rate level this month:** which consumption level the month is heading for and its price per kWh
- **Level warning:** “You are 132 kWh above the 400 kWh level; cutting about 7 kWh a day could save ₱2,369”
- Always-on load in kWh and pesos per month
- The meter’s import reading, the same number Meralco reads
- Brownout and grid-restored alerts from the meter, with advice to protect appliances
- Mira answers questions about use, bill, meter, and saving, without mentioning solar or battery

### Speaker script

Not every household has solar yet. Smart meter mode lets Solaris serve those homes too, using only a smart meter or the Meralco meter.

Solaris reads the meter live, checks whether the voltage is healthy, and learns the household’s usage pattern. It also tracks which Meralco consumption level the month is heading for. Because the whole month is priced by that level, crossing it raises the cost of every kilowatt-hour. Solaris warns the family early and tells them how much to cut each day to stay in the cheaper level.

For solar homes that also have a meter, Solaris uses the meter for the bill, because that is the exact number Meralco charges.

Smart meter mode also opens a path for the business: start with a meter-only home today, and when the family is ready for solar, Solaris already knows their usage and can show what size of system would fit.

### Suggested visual

Show the app in smart meter mode: the house on Home without panels or battery, labelled **HOME** (what the house uses now) and **GRID** (the Meralco supply’s voltage), with the live meter card below it, and the **Meralco level this month** card from the Bill screen.

---

## Slide 11 — Meet Mira

### Title

**Mira explains the customer’s energy data, and shows where every number comes from**

### Suggested questions

- “Mira, bakit mataas ang bill ko?”
- “Gaano katagal ang battery?”
- “Magkano ang bill ko sa Disyembre?”
- “May tao ba sa bahay ngayon?”
- “Biglang tumaas ang gamit namin, bakit?”
- “Nasaang Meralco level na ako ngayong buwan?”
- “Kailangan ko na bang magdagdag ng battery?”

### Speaker script

Mira is the AI energy assistant inside Solaris. Customers can open her from any screen with the floating Mira button.

Instead of requiring customers to interpret graphs and technical values, Mira explains their energy data in simple Taglish.

Mira uses only the household’s actual readings when answering questions, and every answer shows **where it comes from**: the exact readings, forecasts, and settings behind it. Customers can tap a source to open the screen with that data.

Mira is also honest about her limits. She says when a number is only an estimate, and if asked about a bill a year away, she explains why she cannot predict that far instead of guessing.

Mira runs on the home’s own computer, so the household’s questions and data stay private.

---

## Slide 12 — Alerts and Recommendations

### Title

**Clear guidance when something changes**

### App features to show

- Brownout alert and grid-restored notice
- Low-battery warning
- High-temperature warning
- Inverter fault explanation
- Device offline notification
- New appliance-sized load detected
- Notifications for alerts missed while the app was closed
- Recommended actions based on current conditions

### Speaker script

When Solaris detects a brownout, low battery, high temperature, or inverter fault, it immediately alerts the customer.

The app does more than report a problem. It explains the situation and recommends a practical response. During a brownout, for example, Solaris advises the customer to reduce the use of high-consumption appliances to extend the battery. In a home without a battery, it advises unplugging sensitive appliances until the power returns.

This allows customers to respond before a small issue becomes a larger and more expensive problem.

---

## Slide 13 — How Solaris Helps Meralco Serve Its Customers

### Title

**A better-informed customer is an easier customer to serve**

### On-screen points

- **Fewer “bakit mataas ang bill ko?” calls:** the customer sees the bill coming, and why, before it arrives
- **First-line answers at home:** Mira explains bills, rate levels, and usage in Taglish, with sources
- **Usage tracking:** hourly use, peak hours, night share, and the Meralco level the month is heading for
- **Customer profiling, with consent:** household type, always-on load, and new appliances, for better-targeted programs
- **Power-quality evidence:** brownout start and restore times, and low or high voltage, recorded at the home

### Speaker script

Solaris was built for the household, but the same information can help Meralco serve its customers better.

The most common customer-service question is “Why is my bill so high?” Solaris answers it before the bill arrives. The customer sees the forecast, which Meralco consumption level the month is heading for, and what changed, such as a new air conditioner or an always-on load. A customer who already understands the bill is less likely to call the hotline or dispute it.

Mira handles those first questions at home, in Taglish, and shows where every number comes from. When a customer does need to contact Meralco, they arrive with facts, not frustration.

Solaris also tracks usage hour by hour: the busiest hours, how much is used at night, and weekdays versus weekends. With the household’s permission, a summary of this profile could help Meralco offer the right programs to the right homes: energy-efficiency advice for homes with a high always-on load, or usage-shifting tips for homes that peak in the evening.

Finally, Solaris records brownouts and voltage quality at the home itself. A customer can report an outage or a low-voltage problem with exact times and readings, which helps Meralco find and fix the issue faster.

Privacy comes first. By default, everything stays inside the home. The household decides what to share. The daily routine, such as when the family is away, is never shared, because that would be unsafe.

### What works today, and what needs a partnership

| Customer-service need | How Solaris helps | Status |
|---|---|---|
| High-bill inquiries and disputes | Month-to-date cost, month-end forecast with a range, Meralco level warning, “what changed” | Works today, in the app and in Mira |
| Explaining rate levels | Shows the level the month is heading for, and how many kWh a day to cut to stay below the next one | Works today |
| Usage tracking | Hourly use, peak hours, night share, weekday vs weekend, always-on load, the meter’s import reading | Works today |
| Customer profiling and segmentation | Household type, always-on load, and new-appliance detection, shared only as an opt-in summary | Profile works today; sharing with Meralco needs a consent flow and a data link |
| Outage and voltage reports | Brownout start and restore times; low or high voltage with the last 24 hours’ minimum and maximum | Recorded today; sending reports to Meralco needs a partnership |
| Outage awareness by area | Opted-in homes report a brownout the moment it starts | Future: needs many homes and a Meralco data link |
| Peak demand and usage shifting | Tips to move appliance use away from peak hours; solar homes see when they export | Tips work today; Meralco-led programs are future |
| Net-metering questions | Solar + meter mode uses the meter’s billed kWh and shows exports | Works today |

### Suggested visual

A two-sided diagram. On the left, the household’s phone with the bill forecast and Mira. On the right, a Meralco customer-service agent. Between them, a gate labelled “Customer consent” that lets through only opt-in summaries, such as usage by hour, always-on load, and outage times.

### If asked: “Does Meralco see my data?”

No, not by default. Solaris runs on a computer inside the home, and nothing leaves the house unless the customer chooses to share it. Any sharing would be opt-in, a summary rather than raw readings, and it would never include when the family is home or away.

---

## Slide 14 — Why Solaris Matters

### Title

**Useful energy information without technical complexity**

| Current customer experience | With Solaris |
|---|---|
| The cost is discovered when the bill arrives | The bill is forecast before the month ends, with an honest range |
| The inverter displays technical readings | The app provides clear household explanations |
| Problems may be noticed late | Live alerts identify faults and brownouts |
| Battery runtime is uncertain | Remaining runtime is estimated |
| Solar savings are unclear | Daily and monthly savings are visible |
| A new appliance shows up only on the bill | New loads and always-on use are spotted within days |
| Crossing a Meralco rate level is a surprise | Solaris warns early and says how much to cut |
| Homes without solar have nothing to monitor | Smart meter mode works with the meter alone |
| Information is spread across different devices | One application brings the information together |

### Speaker script

Customers invest in solar because they want lower electricity costs. But owning solar equipment does not automatically mean understanding how energy is being used. And homes without solar deserve that understanding too.

Solaris provides that missing visibility.

The Solaris device reads the hybrid inverter, the smart meter, or both. Our system learns the household’s energy behavior and routine. The app shows live conditions and future costs. Mira explains the information, shows where every number comes from, and recommends what the customer can do next.

With Solaris, customers can understand whether their energy is being used well, prepare for their next bill, and make better energy decisions every day.

### Final line

> Solaris helps every home understand its energy today and prepare for its cost tomorrow.

---

# Recommended Live Demo Flow

1. **Open the Home screen.** Show the current solar production, household load, grid importing or exporting, and battery percentage.
2. **Change the simulated solar or household load.** Let the audience see the app update live.
3. **Show the Solar tips card on Home.** Point out today’s best window and the CO₂ avoided this month.
4. **Show the Household card on Home.** Point out the routine strip, “likely home now”, and the new-appliance message. (Seed the demo with `python tools/seed_history.py --reset --new-load-days 5` so a new night-time load appears.)
5. **Open the Energy screen.** Show the daily, weekly, and monthly views.
6. **Open the Bill screen.** Highlight the current cost, predicted month-end bill, forecast range, coming months, and the system check.
7. **Trigger a brownout.** Show the alert and the estimated battery runtime.
8. **Open the solar and battery outlook.** Explain the forecast and projected battery level.
9. **Ask Mira a question.** Use: “Mira, bakit mataas ang bill ko?” or “May bago ba kaming appliance?” Open “Where this answer comes from” under the reply.
10. **Switch to smart meter mode.** In **Settings → Household setup**, choose **Smart meter only** and save. Home now shows the house without panels or battery, labelled **HOME** and **GRID**, with the live meter card and ways to save below it. Open the Bill screen for the **Meralco level this month** card, then ask Mira: “Nasaang Meralco level na ako ngayong buwan?” Mira answers from the meter, without mentioning solar or battery.
11. **Show the Meralco slide.** Use the level card and Mira’s answer from step 10 as the example of a high-bill question answered at home.
12. **Return to the closing slide.** End with the benefit to the customer rather than the technology.

> **Demo note:** Smart meter mode needs meter readings. Seed them with `python tools/seed_history.py --reset --meter` (add `--new-load-days 5` for step 4), or run the simulator in meter mode. Switch the setup back to **Solar** in Settings before you rerun the demo.

---

# Recommended Future Features

## Customer features

- Monthly electricity budget and savings goals
- Notifications when consumption is likely to cross the customer’s target or the next Meralco level
- Appliance-level monitoring through smart plugs or circuit sensors
- Personalized schedules for high-consumption appliances, built from the household routine
- Downloadable monthly energy and savings reports
- An opt-in “Go solar” page for meter-only homes. The sizing, savings, and payback are already calculated on the server from the household’s measured use (`/api/solar-plan`), and the app card is built but not yet shown

## Utility (Meralco) features

- Opt-in sharing: the household chooses which summaries to send to Meralco, such as hourly usage, always-on load, or outage times
- One-tap outage and low-voltage reports to Meralco, with exact times and readings attached
- An area outage map built from opted-in homes that report brownouts as they start
- Customer segments for energy-efficiency and usage-shifting programs, built from opt-in household profiles
- Meralco advisories, such as scheduled interruptions and rate changes, delivered through the app and explained by Mira

## Installer and business features

- Installer dashboard for monitoring multiple customer systems
- Remote fault diagnosis and maintenance notifications
- Upgrade leads from the system check, with the household’s permission
- Compatibility profiles for additional inverter and meter brands
- System-performance reports for warranties and maintenance
- Optional cloud backup and access outside the home network

## Possible business model

- One-time purchase of the Solaris monitoring device
- A lower-cost meter-only package for homes without solar
- Professional installation through solar installers
- Optional subscription for advanced forecasts, reports, and remote monitoring
- Business package for installers, property managers, and small commercial sites

---

# Presentation Tips

- Start with the customer’s electricity bill, not the technical architecture.
- Show the physical Solaris device early so the audience understands that it connects to real energy equipment.
- Keep technical terms such as Modbus, MQTT, SARIMA, and forecasting models in reserve for questions.
- Spend most of the demonstration on the bill forecast, live monitoring, the household profile, brownout runtime, and Mira.
- Mention privacy when presenting the household profile: it is computed on the home’s own computer and never leaves the house.
- Present smart meter mode as a way to reach the many homes without solar, not as a side feature.
- On the Meralco slide, be clear about what works today and what needs a partnership. Do not claim that Meralco already receives Solaris data, or quote call-volume savings we have not measured.
- Avoid claiming guaranteed savings. Explain that Solaris gives customers the information and recommendations needed to make better decisions, and that upgrade prices are estimates.
- End with the customer benefit: visibility, preparation, and control over household energy costs.
