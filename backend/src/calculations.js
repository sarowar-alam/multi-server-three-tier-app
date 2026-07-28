const ACTIVITY_MULTIPLIERS = {
  sedentary:   1.2,
  light:       1.375,
  moderate:    1.55,
  active:      1.725,
  very_active: 1.9,
};

const VALID_SEX_VALUES = ['male', 'female'];

function bmiCategory(bmi) {
  if (bmi < 18.5) return 'Underweight';
  if (bmi < 25)   return 'Normal';
  if (bmi < 30)   return 'Overweight';
  return 'Obese';
}

function calculateMetrics({ weightKg, heightCm, age, sex, activity }) {
  // Guard against values that would produce nonsensical results
  if (!Number.isFinite(weightKg) || weightKg <= 0) throw new Error('Invalid weight');
  if (!Number.isFinite(heightCm) || heightCm <= 0) throw new Error('Invalid height');
  if (!Number.isFinite(age)      || age <= 0)      throw new Error('Invalid age');
  if (!VALID_SEX_VALUES.includes(sex))             throw new Error('Invalid sex');

  const activityMultiplier = ACTIVITY_MULTIPLIERS[activity];
  if (!activityMultiplier) throw new Error(`Invalid activity level: "${activity}"`);

  const heightMeters = heightCm / 100;
  const bmi = +(weightKg / (heightMeters * heightMeters)).toFixed(1);

  // Mifflin-St Jeor formula
  const bmr = sex === 'male'
    ? 10 * weightKg + 6.25 * heightCm - 5 * age + 5
    : 10 * weightKg + 6.25 * heightCm - 5 * age - 161;

  return {
    bmi,
    bmiCategory:   bmiCategory(bmi),
    bmr:           Math.round(bmr),
    dailyCalories: Math.round(bmr * activityMultiplier),
  };
}

module.exports = { calculateMetrics };
